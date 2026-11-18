;; pdv seed engine.
;;
;; Evaluated inside the running backend JVM through the prepl, so this file
;; must stay self contained and require only namespaces that exist on both
;; `iop-vc-preview` and `origin/develop`. Contract:
;; /home/alvar/Code/pdv/wip.local/20261117-pdv-seed/contract.md
;;
;; Entry points: `seed!`, `status`, `export-bundle!`. Every step is
;; idempotent. A second identical call imports nothing and leaves the files
;; the first call imported in place.

(ns pdv.seed
  (:require
   [app.auth :as auth]
   [app.binfile.common :as bfc]
   [app.binfile.v1 :as bfv1]
   [app.binfile.v3 :as bfv3]
   [app.common.features :as cfeat]
   [app.common.logging :as l]
   [app.common.time :as ct]
   [app.common.uuid :as uuid]
   [app.config :as cf]
   [app.db :as db]
   [app.rpc.commands.access-token :as cmd.token]
   [app.rpc.commands.auth :as cmd.auth]
   [app.rpc.commands.profile :as cmd.profile]
   [app.rpc.commands.teams :as teams]
   [app.rpc.permissions :as perms]
   [clojure.java.io :as io]
   [clojure.string :as str])
  (:import
   java.io.PushbackReader))

;; --- system

(defn- current-system
  "The live integrant system of the backend this file was loaded into."
  []
  (or (some-> (requiring-resolve 'app.system/system) deref)
      (some-> (resolve 'user/system) deref)
      (throw (ex-info "no running penpot system"
                      {:type :pdv-seed/no-system
                       :hint "call this from the backend prepl"}))))

(defn- q
  [ds sql & params]
  (db/exec! ds (into [sql] params)))

(defn- q1
  [ds sql & params]
  (db/exec-one! ds (into [sql] params)))

;; --- tables
;;
;; pdv creates `pdv_meta` before the backend starts and before any migration
;; runs, so both tables are created here with the same shape. The backend
;; ignores the tables it does not know.

(def ^:private sql-create-meta
  "create table if not exists pdv_meta (key text primary key, value text)")

(def ^:private sql-create-file
  (str "create table if not exists pdv_seed_file ("
       " id bigserial primary key,"
       " source text not null,"
       " sha256 text,"
       " file_id text,"
       " project_id text,"
       " imported_at timestamptz not null default now(),"
       " verdict text not null default 'imported',"
       " error text)"))

;; A table an older engine created lacks the verdict columns.
(def ^:private sql-add-verdict
  (str "alter table pdv_seed_file"
       " add column if not exists verdict text not null default 'imported',"
       " add column if not exists error text"))

(defn- ensure-tables!
  [system]
  (db/exec! system [sql-create-meta])
  (db/exec! system [sql-create-file])
  (db/exec! system [sql-add-verdict])
  nil)

;; --- meta

(defn- write-meta!
  [{:keys [::db/conn]} key value]
  (db/exec! conn ["insert into pdv_meta (key, value) values (?, ?)
                   on conflict (key) do update set value = excluded.value"
                  key (str value)]))

(def ^:private sql-schema-head
  "select step from migrations
    where module = 'main'
    order by created_at desc, step desc
    limit 1")

(defn- schema-head
  "Name of the last migration applied to this database."
  [system]
  (or (:step (q1 system sql-schema-head))
      (throw (ex-info "no main migration applied to this database"
                      {:type :pdv-seed/not-migrated
                       :hint "wait for the backend to apply its migrations"}))))

;; --- request parsing

(defn- normalize-email
  [email]
  (some-> email str str/trim cmd.profile/clean-email))

(defn- normalize-user
  [{:keys [email fullname password] :as user}]
  (let [email (normalize-email email)]
    (when (str/blank? email)
      (throw (ex-info "seed user without an email"
                      {:type :pdv-seed/invalid-request
                       :user user})))
    {:email email
     :fullname (or (some-> fullname str str/trim not-empty) email)
     :password (or (some-> password str not-empty) "123123")
     :agent? (boolean (:agent? user))}))

(defn- parse-role
  [value]
  (let [role (cond
               (keyword? value) value
               (string? value) (keyword (str/lower-case (str/trim value)))
               :else value)]
    (if (contains? perms/valid-roles role)
      role
      (throw (ex-info (str "invalid team role: " (pr-str value))
                      {:type :pdv-seed/invalid-request
                       :role value})))))

(defn- normalize-member
  [{:keys [email role] :as member}]
  (let [email (normalize-email email)]
    (when (str/blank? email)
      (throw (ex-info "team member without an email"
                      {:type :pdv-seed/invalid-request
                       :member member})))
    {:email email :role (parse-role role)}))

;; --- profiles
;;
;; `cmd.auth/create-profile` merges its own defaults over the props it is
;; given, so the onboarding flags are written afterwards.

(def ^:private onboarded-props
  {:viewed-tutorial? true
   :viewed-walkthrough? true
   :onboarding-viewed true
   :onboarding-questions-answered true})

(defn- ensure-profile!
  "Create or refresh one profile, active and ready for a password login."
  [{:keys [::db/conn] :as system} {:keys [email fullname password]}]
  (let [password (auth/derive-password password)
        profile (cmd.profile/get-profile-by-email conn email)]
    (if (some? profile)
      (do
        (db/update! conn :profile
                    {:fullname fullname
                     :password password
                     :is-active true
                     :deleted-at nil}
                    {:id (:id profile)})
        (assoc profile
               :fullname fullname
               :is-active true
               :deleted-at nil))
      (->> (cmd.auth/create-profile system
                                    {:id (uuid/next)
                                     :email email
                                     :fullname fullname
                                     :password password
                                     :is-active true
                                     :props {}})
           (cmd.auth/create-profile-rels system)))))

;; --- teams and memberships

(def ^:private sql-team-by-name
  "select t.id, t.name
     from team as t
    where t.name = ?
      and t.deleted_at is null
      and exists (select 1
                    from team_profile_rel as r
                   where r.team_id = t.id
                     and r.profile_id = any(?))
    order by t.created_at asc
    limit 1")

(defn- ensure-membership!
  "Give `profile-id` the flags of `role` in `team-id`."
  [{:keys [::db/conn] :as system} team-id profile-id role]
  (let [flags (-> (perms/assign-role-flags {:team-id team-id
                                            :profile-id profile-id}
                                           role)
                  (select-keys [:is-owner :is-admin :can-edit]))
        row (q1 conn "select is_owner, is_admin, can_edit
                        from team_profile_rel
                       where team_id = ? and profile_id = ?"
                team-id profile-id)]
    (if (some? row)
      (when (not= flags (into {} row))
        (db/update! conn :team-profile-rel flags
                    {:team-id team-id :profile-id profile-id}))
      (teams/add-profile-to-team! system
                                  (merge flags {:team-id team-id
                                                :profile-id profile-id})))
    nil))

(defn- ensure-team!
  "Create or adopt the team `name` and set every declared role on it."
  [{:keys [::db/conn] :as system} {:keys [name members]} profiles]
  (let [name (some-> name str str/trim not-empty)
        _ (when (nil? name)
            (throw (ex-info "team without a name"
                            {:type :pdv-seed/invalid-request})))
        members (mapv normalize-member members)
        _ (when (empty? members)
            (throw (ex-info (str "team without members: " name)
                            {:type :pdv-seed/invalid-request
                             :team name})))
        ids (mapv (fn [{:keys [email]}]
                    (or (get-in profiles [email :id])
                        (throw (ex-info (str "team member is not a user: " email)
                                        {:type :pdv-seed/invalid-request
                                         :team name
                                         :email email}))))
                  members)
        acting (or (some (fn [{:keys [email role]}]
                           (when (= :owner role)
                             (get-in profiles [email :id])))
                         members)
                   (first ids))
        features (cfeat/get-enabled-features cf/flags)
        team (or (q1 conn sql-team-by-name name
                     (db/create-array conn "uuid" ids))
                 (teams/create-team system
                                    {:id (uuid/next)
                                     :profile-id acting
                                     :name name
                                     :features features}))]
    (doseq [{:keys [email role]} members]
      (ensure-membership! system (:id team) (get-in profiles [email :id]) role))
    {:id (:id team) :name (:name team) :profile-id acting}))

(defn- resolve-team!
  "Team entry for a bundle or generator, by declared name or the default."
  [{:keys [::db/conn] :as system}
   {:keys [teams-by-name default-team profile-ids acting-profile-id]} team-name]
  (let [team-name (some-> team-name str str/trim not-empty)]
    (cond
      (nil? team-name)
      default-team

      (contains? teams-by-name team-name)
      (get teams-by-name team-name)

      :else
      (if-let [team (q1 conn sql-team-by-name team-name
                        (db/create-array conn "uuid" profile-ids))]
        {:id (:id team)
         :name (:name team)
         :profile-id acting-profile-id}
        (throw (ex-info (str "no team named " team-name)
                        {:type :pdv-seed/invalid-request
                         :team team-name}))))))

;; --- projects
;;
;; A seeded project carries the schema head's number in its name (0159 for
;; 0159-add-file-data-storage-object-id; the migrations table holds the
;; rest), so a database reseeded after a migration gets a fresh project
;; instead of a stale one.

(defn- seeded-project-name
  [label head]
  (str label " · schema " (or (re-find #"^\d+" (str head)) head)))

(defn- ensure-project!
  [{:keys [::db/conn] :as system} team-id profile-id name]
  (or (q1 conn "select id, name from project
                 where team_id = ? and name = ? and deleted_at is null
                 order by created_at asc
                 limit 1"
          team-id name)
      (let [project (teams/create-project conn {:id (uuid/next)
                                                :team-id team-id
                                                :name name})
            now (ct/now)]
        (teams/create-project-role conn profile-id (:id project) :owner)
        (db/insert! conn :team-project-profile-rel
                    {:id (uuid/next)
                     :team-id team-id
                     :project-id (:id project)
                     :profile-id profile-id
                     :is-pinned false
                     :created-at now
                     :modified-at now}
                    ::db/on-conflict-do-nothing? true)
        project)))

(defn- ensure-project-for!
  "Resolve the team of a bundle and return its project, created if absent."
  [system ctx team-name label]
  (db/tx-run!
   system
   (fn [system]
     (let [team (resolve-team! system ctx team-name)
           name (seeded-project-name label (:schema-head ctx))
           project (ensure-project! system (:id team) (:profile-id team) name)]
       {:team-id (:id team)
        :profile-id (:profile-id team)
        :project-id (:id project)
        :project-name (:name project)}))))

;; --- seed records

(def ^:private sql-recorded
  "select 1 as one from pdv_seed_file
    where source = ? and sha256 is not distinct from ?
      and verdict <> 'failed'
    limit 1")

(defn- recorded?
  "True when this (source, sha256) was imported. A failed row does not
  count, so the next seed tries the item again."
  [system source sha256]
  (some? (q1 system sql-recorded source sha256)))

(defn- record!
  "One row per imported file. An empty import still records a row."
  [system {:keys [source sha256 file-ids project-id]}]
  (doseq [file-id (or (seq file-ids) [nil])]
    (db/insert! system :pdv-seed-file
                {:source source
                 :sha256 sha256
                 :file-id (some-> file-id str)
                 :project-id (str project-id)
                 :imported-at (ct/now)}))
  nil)

(defn- forget-failures!
  "Drop the failed rows of (source, sha256) before the item is tried again."
  [system source sha256]
  (db/exec! system ["delete from pdv_seed_file
                      where source = ? and sha256 is not distinct from ?
                        and verdict = 'failed'"
                    source sha256])
  nil)

;; --- failures
;;
;; A failed item is reported by its message, its code, and the schema paths
;; of the values the check refused. The paths drop every uuid, so one bad
;; attribute repeated over a hundred shapes reads as one path.

(defn- cause-chain
  [^Throwable t]
  (take-while some? (iterate #(some-> ^Throwable % .getCause) t)))

(defn- schema-explain
  "The first malli explain carried by the exception or one of its causes."
  [t]
  (some (fn [c] (:app.common.schema/explain (ex-data c))) (cause-chain t)))

(defn- error-paths
  "Distinct value paths of an explain, uuids removed."
  [explain]
  (into [] (comp (map (fn [{:keys [in]}] (into [] (remove uuid?) in)))
                 (distinct))
        (:errors explain)))

(defn- failure
  "What a failed item reports: message, code, and schema paths."
  [t]
  (let [code (some (fn [c] (:code (ex-data c))) (cause-chain t))
        paths (error-paths (schema-explain t))
        shown (vec (take 5 paths))]
    {:message (or (ex-message t) (.getName (class t)))
     :code (some-> code str)
     :paths shown
     :more-paths (- (count paths) (count shown))}))

(defn- failure-text
  "One line for the `error` column."
  [{:keys [message code paths more-paths]}]
  (str message
       (when code (str " (code " code ")"))
       (when (seq paths) (str " at " (str/join " " (map pr-str paths))))
       (when (pos? more-paths) (str " and " more-paths " more"))))

(defn- record-failure!
  [system source sha256 error]
  (db/insert! system :pdv-seed-file
              {:source source
               :sha256 sha256
               :imported-at (ct/now)
               :verdict "failed"
               :error (failure-text error)})
  nil)

(defn- file-names
  "Names of the imported files, for the per-item report."
  [system file-ids]
  (if (empty? file-ids)
    []
    (db/tx-run!
     system
     (fn [{:keys [::db/conn]}]
       (mapv :name (q conn "select name from file where id = any(?) order by name"
                      (db/create-array conn "uuid" (mapv parse-uuid file-ids))))))))

(defn- attempt
  "Run one item. With keep-going, a throw records a failed row and returns
  the failed verdict; without it, the throw aborts the seed."
  [system ctx {:keys [source sha256 label]} f]
  (forget-failures! system source sha256)
  (if-not (:keep-going? ctx)
    (f)
    (try
      (f)
      (catch Exception e
        (let [error (failure e)]
          (l/wrn :hint "pdv seed: item failed" :source source :error (failure-text error))
          (record-failure! system source sha256 error)
          {:source source
           :verdict :failed
           :names [label]
           :error error})))))

;; --- bundles

(defn- source-stem
  "Project name a bundle defaults to. Uses the file name of the source, from
  the fragment of a `git+` source or the last path segment of a plain one."
  [source]
  (let [source (str/replace (str source) #"#sha256=[0-9a-fA-F]+$" "")
        base (if (str/includes? source "#")
               (last (str/split source #"#"))
               (last (str/split source #"/")))
        base (str/replace (str base) #"(?i)\.penpot$" "")]
    (if (str/blank? base) "bundle" base)))

(defn- parent-name
  "Last directory of a path, or nil when the path has no directory part."
  [path]
  (let [parts (str/split (str path) #"/")]
    (when (> (count parts) 1)
      (let [dir (nth parts (- (count parts) 2))]
        (some-> dir str/trim not-empty)))))

(defn- generator-label
  "Project name a generator defaults to. A generator is the directory that
  holds its script, so the directory name beats the script name."
  [script]
  (or (parent-name script)
      (str/replace (last (str/split (str script) #"/")) #"(?i)\.clj$" "")))

(defn- import-package!
  "Import one staged package. The magic bytes decide the format: v1 is a
  zstd stream, v3 is a zip. Both return `{:file-ids [...]}`."
  [system {:keys [profile-id team-id project-id]} input source]
  (let [format (bfc/parse-file-format input)
        ;; The import RPC's own lookup: app.binfile.common/get-team exists on
        ;; develop but not on staging, and a seed must load on both.
        cfg (bfc/import-cfg system
                            {:profile-id profile-id
                             :project-id project-id
                             :team (teams/get-team system
                                                   :profile-id profile-id
                                                   :team-id team-id)
                             :name nil
                             :input input})]
    (case format
      :binfile-v1 (bfv1/import-files! cfg)
      :binfile-v3 (bfv3/import-files! cfg)
      (throw (ex-info (str "unknown penpot package format: " (pr-str format))
                      {:type :pdv-seed/invalid-request
                       :source source
                       :format format})))))

(defn- import-bundle!
  "Import one bundle, unless this (source, sha256) is already recorded.
  Returns the item's report row."
  [system ctx {:keys [path source sha256 team project]}]
  (let [source (or (some-> source str not-empty) (some-> path str not-empty))
        _ (when (nil? source)
            (throw (ex-info "bundle without a source"
                            {:type :pdv-seed/invalid-request
                             :path path})))
        sha256 (some-> sha256 str not-empty)]
    (if (recorded? system source sha256)
      (do
        (l/dbg :hint "pdv seed: bundle already imported" :source source)
        {:source source :verdict :recorded})
      (attempt
       system ctx {:source source :sha256 sha256 :label (source-stem source)}
       (fn []
         (let [^java.io.File file (io/file (str path))
               _ (when-not (.isFile file)
                   (throw (ex-info (str "bundle not found: " path)
                                   {:type :pdv-seed/invalid-request
                                    :path path
                                    :source source})))
               label (or (some-> project str not-empty) (source-stem source))
               {:keys [team-id profile-id project-id project-name]}
               (ensure-project-for! system ctx team label)
               result (import-package! system
                                       {:profile-id profile-id
                                        :team-id team-id
                                        :project-id project-id}
                                       (.toPath file)
                                       source)
               file-ids (into [] (comp (map str) (distinct)) (:file-ids result))]
           (record! system {:source source
                            :sha256 sha256
                            :file-ids file-ids
                            :project-id project-id})
           (l/inf :hint "pdv seed: bundle imported"
                  :source source
                  :project project-name
                  :files (count file-ids))
           {:source source
            :verdict :imported
            :file-ids file-ids
            :names (file-names system file-ids)
            :project project-name}))))))

;; --- generators
;;
;; A generator script is a Clojure file that defines `generate!`. It is
;; loaded here and called with the live system, its own absolute path, and
;; the resolved ids, so the generated files land in a seeded project and
;; sibling files are found without a hard-coded directory.

(defn- script-namespace
  "Namespace declared by a generator script, or nil when it declares none."
  [^java.io.File file]
  (with-open [rdr (PushbackReader. (io/reader file))]
    (loop []
      (let [form (read {:eof ::eof
                        :read-cond :allow
                        :features #{:clj}}
                       rdr)]
        (cond
          (= ::eof form) nil
          (and (seq? form) (= 'ns (first form))) (second form)
          :else (recur))))))

(defn- load-generator!
  [^String path]
  (let [file (io/file path)]
    (when-not (.isFile file)
      (throw (ex-info (str "generator not found: " path)
                      {:type :pdv-seed/invalid-request
                       :script path})))
    (let [nsname (script-namespace file)
          _ (load-file (str file))
          gen (when (some? nsname)
                (some-> (find-ns nsname) (ns-resolve 'generate!)))]
      (when-not (ifn? gen)
        (throw (ex-info (str "no generate! found in " path)
                        {:type :pdv-seed/invalid-request
                         :script path
                         :namespace (some-> nsname str)})))
      gen)))

(defn- run-generator!
  "Run one generator, unless this (script, input hash) is already recorded.
  Returns the item's report row."
  [system ctx {:keys [script args team project]}]
  (let [source (some-> script str not-empty)
        _ (when (nil? source)
            (throw (ex-info "generator without a script"
                            {:type :pdv-seed/invalid-request})))
        sha256 (some-> (:input-hash ctx) str not-empty)]
    (if (recorded? system source sha256)
      (do
        (l/dbg :hint "pdv seed: generator already run" :script source)
        {:source source :verdict :recorded})
      (attempt
       system ctx {:source source :sha256 sha256 :label (generator-label source)}
       (fn []
         (let [label (or (some-> project str not-empty) (generator-label source))
               {:keys [team-id profile-id project-id project-name]}
               (ensure-project-for! system ctx team label)
               gen (load-generator! source)
               result (gen {:system system
                            :script source
                            :profile-id profile-id
                            :team-id team-id
                            :project-id project-id
                            :args (or args {})})
               file-ids (into [] (comp (map str) (distinct)) result)]
           (record! system {:source source
                            :sha256 sha256
                            :file-ids file-ids
                            :project-id project-id})
           (l/inf :hint "pdv seed: generator finished"
                  :script source
                  :project project-name
                  :files (count file-ids))
           {:source source
            :verdict :imported
            :file-ids file-ids
            :names (file-names system file-ids)
            :project project-name}))))))

;; --- access tokens
;;
;; The plaintext token is not recoverable from the database, so a seed run
;; always replaces the token named `pdv` of an agent user.

(defn- mint-token!
  [system profile-id]
  (db/tx-run!
   system
   (fn [{:keys [::db/conn] :as system}]
     (db/exec! conn ["delete from access_token
                       where profile_id = ? and name = 'pdv'"
                     profile-id])
     ;; repl:create-access-token passes four arguments to a five-argument
     ;; function on both iop-vc-preview and develop, so call the function
     ;; itself, with the nil type the create-access-token RPC passes.
     (let [token (cmd.token/create-access-token
                  system profile-id "pdv" nil nil)]
       (:token token)))))

;; --- prepare

(defn- prepare!
  "Create the profiles, teams and memberships of one request."
  [system {:keys [users teams hash] :as request}]
  (let [users (mapv normalize-user users)]
    (when (empty? users)
      (throw (ex-info "the seed request declares no users"
                      {:type :pdv-seed/invalid-request
                       :request request})))
    (let [profiles (into {}
                         (map (fn [user]
                                [(:email user) (ensure-profile! system user)]))
                         users)
          _ (doseq [user users]
              (cmd.profile/update-profile-props
               system (get-in profiles [(:email user) :id]) onboarded-props))
          teams (mapv #(ensure-team! system % profiles) teams)
          first-profile (get profiles (:email (first users)))
          default (or (first teams)
                      (let [team-id (:default-team-id first-profile)]
                        (when (nil? team-id)
                          (throw (ex-info "user has no default team"
                                          {:type :pdv-seed/invalid-request
                                           :email (:email first-profile)})))
                        {:id team-id
                         :name "Default"
                         :profile-id (:id first-profile)}))]
      {:users users
       :profiles profiles
       :profile-ids (mapv :id (vals profiles))
       :acting-profile-id (:id first-profile)
       :teams teams
       :teams-by-name (into {} (map (juxt :name identity)) teams)
       :default-team default
       :input-hash hash
       :keep-going? (true? (:keep-going request))})))

;; --- files of a project

(def ^:private sql-table-column
  "select 1 as one
     from information_schema.columns
    where table_name = ?
      and column_name = ?
    limit 1")

(defn- has-column?
  [system table column]
  (some? (q1 system sql-table-column table column)))

(defn- project-files
  "Files of a project, branch files excluded on a branch aware database."
  [system project-id]
  (let [sql (str "select id, name from file"
                 " where project_id = ?"
                 " and deleted_at is null"
                 (when (has-column? system "file" "is_branch")
                   " and is_branch is not true")
                 " order by created_at asc, name asc")]
    (q system sql project-id)))

;; --- project lookup for export

(def ^:private sql-project-by-team
  "select p.id, p.name, t.name as team_name
     from project as p
     join team as t on (t.id = p.team_id)
    where p.deleted_at is null
      and t.deleted_at is null
      and t.name = ?
      and p.name in (?, ?)
    order by p.created_at asc")

(def ^:private sql-project-any-team
  "select p.id, p.name, t.name as team_name
     from project as p
     join team as t on (t.id = p.team_id)
    where p.deleted_at is null
      and t.deleted_at is null
      and p.name in (?, ?)
    order by p.created_at asc")

(defn- find-project!
  "Project by name, preferring the one a seed created under the current
  schema head over a project that carries the plain name."
  [{:keys [::db/conn] :as system} team-name project-name head]
  (let [project-name (some-> project-name str str/trim not-empty)
        _ (when (nil? project-name)
            (throw (ex-info "no project name given"
                            {:type :pdv-seed/invalid-request})))
        team-name (some-> team-name str str/trim not-empty)
        versioned (seeded-project-name project-name head)
        rows (if (nil? team-name)
               (q conn sql-project-any-team versioned project-name)
               (q conn sql-project-by-team team-name versioned project-name))]
    (or (first (filter #(= versioned (:name %)) rows))
        (first rows)
        (throw (ex-info (str "no project named " project-name)
                        {:type :pdv-seed/not-found
                         :project project-name
                         :team team-name})))))

;; --- public api

(defn seed!
  "Seed this database from one profile.

  Request: `{:slug :hash :profile :keep-going :users :teams :bundles
  :generators}`. Returns `{:users :teams :items :schema-head :secrets}`
  with uuids as strings, one item row per bundle and generator, and the
  agent tokens keyed by email. An item row's `:verdict` is `:imported`,
  `:recorded` (imported by an earlier seed), or `:failed`, which only a
  `:keep-going` request returns instead of throwing."
  [request]
  (let [system (current-system)
        _ (ensure-tables! system)
        head (schema-head system)
        ctx (-> (db/tx-run! system #(prepare! % request))
                (assoc :schema-head head))
        items (into (mapv #(import-bundle! system ctx %) (:bundles request))
                    (map #(run-generator! system ctx %))
                    (:generators request))
        secrets (reduce (fn [result {:keys [email agent?]}]
                          (if agent?
                            (let [profile-id (get-in ctx [:profiles email :id])]
                              (assoc result email (mint-token! system profile-id)))
                            result))
                        {}
                        (:users ctx))]
    (db/tx-run!
     system
     (fn [system]
       (write-meta! system "input_hash" (str (:hash request)))
       (write-meta! system "schema_head" head)
       (write-meta! system "seeded_at" (str (ct/now)))
       (when-let [profile (some-> (:profile request) str str/trim not-empty)]
         (write-meta! system "profile" profile))))
    (l/inf :hint "pdv seed: finished"
           :slug (:slug request)
           :imported (count (filter #(= :imported (:verdict %)) items))
           :failed (count (filter #(= :failed (:verdict %)) items))
           :schema-head head)
    {:users (count (:users ctx))
     :teams (count (:teams ctx))
     :items items
     :schema-head head
     :secrets secrets}))

(def ^:private sql-files
  "select f.source, f.sha256, f.file_id, f.project_id, f.imported_at,
          p.name as project_name
     from pdv_seed_file as f
     left join project as p on (p.id = f.project_id::uuid)
    where f.verdict <> 'failed'
    order by f.source asc, f.imported_at asc, f.file_id asc")

(def ^:private sql-failures
  "select source, error from pdv_seed_file
    where verdict = 'failed'
    order by source asc")

(defn status
  "What this database holds: the pdv_meta map, the seed records, and the
  items whose last attempt failed."
  []
  (let [system (current-system)]
    (ensure-tables! system)
    {:meta (into {}
                 (map (fn [{:keys [key value]}] [(keyword key) value]))
                 (q system "select key, value from pdv_meta order by key"))
     :files (->> (q system sql-files)
                 (group-by (juxt :source :sha256))
                 (map (fn [[[source sha256] rows]]
                        {:source source
                         :sha256 sha256
                         :project (:project_name (first rows))
                         :file-ids (mapv (comp str :file_id) rows)}))
                 (sort-by (juxt :source (comp str :sha256)))
                 vec)
     :failures (mapv #(select-keys % [:source :error]) (q system sql-failures))}))

(defn export-bundle!
  "Export every file of a project, libraries included, into one `.penpot`.
  Returns the exported file names."
  [{:keys [team project out]}]
  (let [system (current-system)
        head (schema-head system)
        target (db/tx-run! system #(find-project! % team project head))
        name (:name target)
        files (project-files system (:id target))
        _ (when (empty? files)
            (throw (ex-info (str "project has no files: " name)
                            {:type :pdv-seed/not-found
                             :project name})))
        output (io/file (str out))]
    (some-> output .getParentFile .mkdirs)
    (bfv3/export-files! (-> system
                            (assoc ::bfc/file-ids (into #{} (map :id) files))
                            (assoc ::bfc/export-type :include-libraries)
                            (assoc ::bfc/output output)))
    (l/inf :hint "pdv seed: project exported"
           :project name
           :out (str out)
           :files (count files))
    (mapv :name files)))
