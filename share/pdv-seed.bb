#!/usr/bin/env bb
;; pdv seed driver, container side.
;;
;; Contract: penpot/pdv wip.local/20261117-pdv-seed/contract.md, sections
;; "Container-side driver" and "Remote sources and the download cache".
;;
;; stdout carries the protocol, stderr carries human text. Exit 0 on success,
;; 1 on a refused profile (or a refused flag), 2 on an internal error.
;;
;; The staging root is /tmp/pdv-seed, and PDV_SEED_DIR relocates it for testing.

(ns pdv-seed
  (:require [babashka.fs :as fs]
            [babashka.http-client :as http]
            [bencode.core :as bencode]
            [cheshire.core :as json]
            [clj-yaml.core :as yaml]
            [clojure.edn :as edn]
            [clojure.string :as str])
  (:import (java.io BufferedInputStream BufferedOutputStream PushbackInputStream)
           (java.net InetSocketAddress Socket URLEncoder)
           (java.nio.file Files OpenOption)
           (java.nio.file.attribute FileAttribute PosixFilePermissions)
           (java.security MessageDigest)))

;; ---------------------------------------------------------------- paths

(def ^:private seed-dir (or (System/getenv "PDV_SEED_DIR") "/tmp/pdv-seed"))
(def ^:private profile-path (fs/path seed-dir "profile.yaml"))
(def ^:private engine-path (fs/path seed-dir "seed.clj"))
(def ^:private repo-root (fs/path seed-dir "repo"))
(def ^:private remote-root (fs/path seed-dir "remote"))
(def ^:private secret-root (fs/path seed-dir "secret"))
(def ^:private out-root (fs/path seed-dir "out"))
;; Internal handoff from needs to apply, not part of the stdout protocol.
(def ^:private remote-index-path (fs/path seed-dir "remote-index.tsv"))

(def ^:private nrepl-host "127.0.0.1")
(def ^:private nrepl-port 6064)
;; Bundle imports and generator runs take a while.
(def ^:private nrepl-timeout-ms (* 60 60 1000))
(def ^:private default-password "123123")

(def ^:private roles #{"owner" "admin" "editor" "viewer"})
(def ^:private top-keys #{:description :users :teams :bundles :generators})
(def ^:private user-keys #{:email :fullname :password :password_file :agent})
(def ^:private team-keys #{:name :members})
(def ^:private member-keys #{:email :role})
(def ^:private bundle-keys #{:source :team :project})
(def ^:private generator-keys #{:script :args :team :project})
(def ^:private email-re #"^[^\s@]+@[^\s@]+\.[^\s@]+$")
(def ^:private slug-re #"[a-z0-9_]{1,40}")
(def ^:private database-re #"[a-z0-9_-]{1,63}")
(def ^:private profile-name-re #"[A-Za-z0-9._-]{1,64}")
(def ^:private hash-re #"[0-9a-f]{64}")
(def ^:private lfs-pointer-prefix "version https://git-lfs.github.com/spec/")

;; Credentials seen by this run, so no message can echo one back.
(def ^:private secret-values (atom #{}))

;; Penpot access tokens are JWE, five dot-separated base64url segments, and a JWT
;; is three. Mask either even when no seed has returned one yet.
(def ^:private token-like-re #"\beyJ[A-Za-z0-9_-]{8,}(\.[A-Za-z0-9_-]+){2,4}\b")

;; ---------------------------------------------------------------- output

(defn- redact
  "Replace every credential this run has seen with ***."
  [s]
  (-> (reduce (fn [acc v]
                (if (str/blank? v)
                  acc
                  (str/replace acc (re-pattern (java.util.regex.Pattern/quote v)) "***")))
              (str s)
              @secret-values)
      (str/replace token-like-re "***")))

(defn- say
  "Human text on stderr, credential-free."
  [fmt & args]
  (binding [*out* *err*]
    (println (redact (apply format fmt args)))
    (flush)))

(defn- die
  "Message on stderr, then exit with code."
  [code fmt & args]
  (apply say fmt args)
  (System/exit code))

(defn- refuse [fmt & args]
  (apply die 1 fmt args))

(defn- truncate [s n]
  (let [s (str s)]
    (if (> (count s) n) (str (subs s 0 n) "...") s)))

;; ---------------------------------------------------------------- hashing

(defn- hex [^bytes bs]
  (apply str (map #(format "%02x" (bit-and (int %) 0xff)) bs)))

(defn- open-in [path]
  (Files/newInputStream (fs/path path) (make-array OpenOption 0)))

(defn- sha256-file [path]
  (let [md (MessageDigest/getInstance "SHA-256")
        buf (byte-array 65536)]
    (with-open [in (open-in path)]
      (loop []
        (let [n (.read in buf)]
          (when (pos? n)
            (.update md buf 0 n)
            (recur)))))
    (hex (.digest md))))

(defn- sha256-string [s]
  (hex (.digest (doto (MessageDigest/getInstance "SHA-256")
                  (.update (.getBytes (str s) "UTF-8"))))))

(defn- lfs-pointer? [path]
  (with-open [in (open-in path)]
    (let [buf (byte-array 64)
          n (.read in buf)]
      (and (pos? n)
           (str/starts-with? (String. buf 0 n "UTF-8") lfs-pointer-prefix)))))

;; ---------------------------------------------------------------- profile values

(defn- plain
  "Ordered maps and lazy seqs from clj-yaml become plain EDN collections."
  [x]
  (cond
    (map? x) (into {} (map (fn [[k v]] [(if (keyword? k) k (keyword (str k))) (plain v)]) x))
    (sequential? x) (mapv plain x)
    :else x))

(defn- yaml-value?
  "True when every part of v prints as readable EDN."
  [v]
  (cond
    (nil? v) true
    (or (string? v) (boolean? v) (number? v)) true
    (sequential? v) (every? yaml-value? v)
    (map? v) (every? (fn [[k v]] (and (keyword? k) (yaml-value? v))) v)
    :else false))

(defn- non-blank-string? [v]
  (and (string? v) (not (str/blank? v))))

(defn- norm-rel
  "Strip trailing slashes from a repository-relative path."
  [p]
  (str/replace (str p) #"/+$" ""))

(defn- path-segments [p]
  (str/split p #"/"))

(defn- safe-relpath?
  "A relative path inside the fixture repository, with no way out of it."
  [p]
  (and (non-blank-string? p)
       (not (str/starts-with? p "/"))
       (not (str/starts-with? p "~"))
       (not (str/includes? p "\\"))
       (not (re-find #"[\t\n\r]" p))
       (every? (fn [seg] (and (not (str/blank? seg))
                              (not= "." seg)
                              (not= ".." seg)))
               (path-segments p))))

(defn- file-stem
  "The last path segment without its extension."
  [p]
  (str/replace (last (path-segments (norm-rel p))) #"\.[^.]+$" ""))

(defn- dir-name [dir]
  (last (path-segments dir)))

(defn- source-kind [source]
  (cond
    (str/starts-with? source "git+") :git
    (str/starts-with? source "https://") :https
    (re-find #"^[A-Za-z][A-Za-z0-9+.-]*://" source) :unknown
    :else :repo))

(defn- parse-git-source
  "git+https://github.com/<owner>/<repo>@<rev>#<path> -> parts, or [nil error]."
  [source]
  (let [rest (subs source 4)
        h (str/index-of rest "#")]
    (if (nil? h)
      [nil "a git+ source needs a #path fragment"]
      (let [base (subs rest 0 h)
            path (subs rest (inc h))
            m (re-matches #"https://github\.com/([^/]+)/([^/@]+)@(.+)" base)]
        (cond
          (str/blank? path)
          [nil "the #path fragment of a git+ source is empty"]

          (nil? m)
          [nil "a git+ source must read git+https://github.com/<owner>/<repo>@<rev>#<path>"]

          :else
          [{:owner (nth m 1) :repo (nth m 2) :rev (nth m 3) :path path} nil])))))

(defn- parse-https-source
  "https://<url>#sha256=<hex> -> parts, or [nil error]."
  [source]
  (let [h (str/index-of source "#")]
    (if (nil? h)
      [nil "an https source needs a #sha256=<64 hex digits> fragment"]
      (let [url (subs source 0 h)
            m (re-matches #"sha256=([0-9a-fA-F]{64})" (subs source (inc h)))]
        (if (nil? m)
          [nil "the # fragment of an https source must read sha256=<64 hex digits>"]
          [{:url url :sha256 (str/lower-case (nth m 1))} nil])))))

;; ---------------------------------------------------------------- profile checks

(defn- unknown-keys [bad! path allowed m]
  (doseq [k (keys m)]
    (when-not (contains? allowed k)
      (bad! "%s has unknown key %s" path (pr-str k)))))

(defn- dupes [bad! path coll]
  (doseq [[v n] (frequencies coll)]
    (when (> n 1)
      (bad! "%s lists %s %d times" path v n))))

(defn- map-item [bad! path item]
  (if (map? item) item (do (bad! "%s must be a mapping" path) {})))

(defn- check-email [bad! path email]
  (cond
    (nil? email) (bad! "%s has no email" path)
    (not (string? email)) (bad! "%s.email must be a string" path)
    (not (re-matches email-re email))
    (bad! "%s.email is not an email address: %s" path email)))

(defn- email-local [email]
  (first (str/split email #"@")))

(defn- normalize-user [bad! i item]
  (let [path (str "users[" i "]")
        u (map-item bad! path item)
        email (:email u)
        fullname (:fullname u)
        password (:password u)
        password-file (:password_file u)
        agent (:agent u)]
    (unknown-keys bad! path user-keys u)
    (check-email bad! path email)
    (when (some? fullname)
      (when-not (non-blank-string? fullname)
        (bad! "%s.fullname must be a non-empty string" path)))
    (when (some? password)
      (when-not (non-blank-string? password)
        (bad! "%s.password must be a non-empty string, quoted in YAML" path)))
    (when (some? password-file)
      (when-not (and (non-blank-string? password-file)
                     (re-find #"^(~|/)" password-file)
                     (not (re-find #"[\t\n\r]" password-file)))
        (bad! "%s.password_file must start with ~ or /, with no tabs or newlines" path)))
    (when (some? agent)
      (when-not (boolean? agent)
        (bad! "%s.agent must be true or false" path)))
    {:email email
     :fullname (if (non-blank-string? fullname)
                 fullname
                 (when (string? email) (email-local email)))
     :password (when (non-blank-string? password) password)
     :password-file (when (non-blank-string? password-file) password-file)
     :agent? (true? agent)}))

(defn- validate-users [bad! raw]
  (let [users (mapv (fn [i item] (normalize-user bad! i item)) (range) raw)]
    (dupes bad! "users" (keep #(when (string? (:email %)) (str/lower-case (:email %))) users))
    users))

(defn- user-emails [users]
  (into #{} (keep #(when (string? (:email %)) (str/lower-case (:email %))) users)))

(defn- normalize-member [bad! path j emails item]
  (let [mpath (str path ".members[" j "]")
        m (map-item bad! mpath item)
        email (:email m)
        role (:role m)]
    (unknown-keys bad! mpath member-keys m)
    (cond
      (nil? email) (bad! "%s has no email" mpath)
      (not (string? email)) (bad! "%s.email must be a string" mpath)
      (not (contains? emails (str/lower-case (str email))))
      (bad! "%s names %s, which users does not declare" mpath email))
    (cond
      (nil? role) (bad! "%s has no role" mpath)
      (not (string? role)) (bad! "%s.role must be a string" mpath)
      (not (contains? roles role))
      (bad! "%s.role must be one of %s, not %s"
            mpath (str/join ", " (sort roles)) role))
    {:email email :role role}))

(defn- normalize-team [bad! i emails item]
  (let [path (str "teams[" i "]")
        t (map-item bad! path item)
        name (:name t)
        members (:members t)]
    (unknown-keys bad! path team-keys t)
    (when-not (non-blank-string? name)
      (bad! "%s.name must be a non-empty string" path))
    (when (and (some? members) (not (sequential? members)))
      (bad! "%s.members must be a list" path))
    (let [members (if (sequential? members) (vec members) [])
          members' (mapv (fn [j m] (normalize-member bad! path j emails m)) (range) members)]
      (dupes bad! path (keep #(when (string? (:email %)) (str/lower-case (:email %))) members'))
      {:name name :members members'})))

(defn- validate-teams [bad! raw emails]
  (let [teams (mapv (fn [i item] (normalize-team bad! i emails item)) (range) raw)]
    (dupes bad! "teams" (keep #(when (non-blank-string? (:name %)) (:name %)) teams))
    teams))

(defn- declared-teams [teams]
  (into #{} (keep #(when (non-blank-string? (:name %)) (:name %)) teams)))

(defn- check-team [bad! path team-names entry]
  (when (some? (:team entry))
    (cond
      (not (non-blank-string? (:team entry)))
      (bad! "%s.team must be a non-empty string" path)
      (not (contains? team-names (:team entry)))
      (bad! "%s names team %s, which teams does not declare" path (:team entry)))))

(defn- check-project [bad! path entry]
  (when (some? (:project entry))
    (when-not (non-blank-string? (:project entry))
      (bad! "%s.project must be a non-empty string" path))))

(defn- git-source-fields [bad! path source base]
  (let [[parsed err] (parse-git-source source)]
    (if err
      (do (bad! "%s.source: %s" path err) (assoc base :kind :git))
      (assoc base :kind :git
             :git parsed
             :project (or (:project base) (file-stem (:path parsed)))))))

(defn- https-source-fields [bad! path source base]
  (let [[parsed err] (parse-https-source source)]
    (if err
      (do (bad! "%s.source: %s" path err) (assoc base :kind :https))
      (assoc base :kind :https
             :url (:url parsed)
             :sha256 (:sha256 parsed)
             :project (or (:project base) (file-stem (:url parsed)))))))

(defn- bundle-source-fields [bad! path source base]
  (cond
    (nil? source) (do (bad! "%s has no source" path) base)
    (not (string? source)) (do (bad! "%s.source must be a string" path) base)
    :else
    (case (source-kind source)
      :repo
      (if (safe-relpath? source)
        (assoc base :kind :repo
               :relpath (norm-rel source)
               :project (or (:project base) (file-stem source)))
        (do (bad! "%s.source must stay inside the fixture repository, with no .. or leading /" path)
            (assoc base :kind :repo)))
      :git (git-source-fields bad! path source base)
      :https (https-source-fields bad! path source base)
      :unknown
      (do (bad! "%s.source names a scheme only git+ and https:// support" path)
          (assoc base :kind :unknown)))))

(defn- normalize-bundle [bad! i team-names item]
  (let [path (str "bundles[" i "]")
        b (map-item bad! path item)]
    (unknown-keys bad! path bundle-keys b)
    (check-team bad! path team-names b)
    (check-project bad! path b)
    (bundle-source-fields bad! path (:source b)
                          {:source (:source b)
                           :team (when (non-blank-string? (:team b)) (:team b))
                           :project (when (non-blank-string? (:project b)) (:project b))})))

(defn- validate-bundles [bad! raw team-names]
  (mapv (fn [i item] (normalize-bundle bad! i team-names item)) (range) raw))

(defn- normalize-generator [bad! i team-names item]
  (let [path (str "generators[" i "]")
        g (map-item bad! path item)
        script (:script g)
        args (:args g)]
    (unknown-keys bad! path generator-keys g)
    (check-team bad! path team-names g)
    (check-project bad! path g)
    (cond
      (nil? script) (bad! "%s has no script" path)
      (not (string? script)) (bad! "%s.script must be a string" path)
      (not (safe-relpath? script))
      (bad! "%s.script must stay inside the fixture repository, with no .. or leading /" path)
      (not (re-find #"\.(clj|cljc|bb)$" script))
      (bad! "%s.script must end in .clj, .cljc or .bb" path))
    (when (some? args)
      (cond
        (not (map? args)) (bad! "%s.args must be a mapping" path)
        (not (yaml-value? args))
        (bad! "%s.args holds a value YAML reads as a date or binary, quote it" path)))
    (let [relpath (when (and (string? script) (safe-relpath? script)) (norm-rel script))
          dir (when relpath (str/join "/" (butlast (path-segments relpath))))]
      (when (and relpath (str/blank? dir))
        (bad! "%s.script must live in a directory, so its whole directory can be staged" path))
      {:script relpath
       :dir dir
       :args args
       :team (when (non-blank-string? (:team g)) (:team g))
       :project (or (when (non-blank-string? (:project g)) (:project g))
                    (when-not (str/blank? (str dir)) (dir-name dir)))})))

(defn- validate-generators [bad! raw team-names]
  (mapv (fn [i item] (normalize-generator bad! i team-names item)) (range) raw))

(defn- list-section [bad! key data]
  (let [v (get data key)]
    (cond
      (nil? v) []
      (sequential? v) (vec v)
      :else (do (bad! "%s must be a list" key) []))))

(defn- validate-profile
  "Refuse a profile the engine cannot honour, else return the normalized form."
  [text data]
  (let [errs (atom [])
        bad! (fn [fmt & args] (swap! errs conj (apply format fmt args)))]
    (when-not (map? data)
      (bad! "the top level must be a mapping"))
    (let [data (if (map? data) data {})]
      (unknown-keys bad! "the profile" top-keys data)
      (when (some? (:description data))
        (when-not (string? (:description data))
          (bad! "description must be a string")))
      (let [users (validate-users bad! (list-section bad! :users data))
            _ (when (empty? users) (bad! "users must list at least one user"))
            teams (validate-teams bad! (list-section bad! :teams data) (user-emails users))
            team-names (declared-teams teams)
            bundles (validate-bundles bad! (list-section bad! :bundles data) team-names)
            generators (validate-generators bad! (list-section bad! :generators data) team-names)]
        ;; A nudge, never a refusal: names are how a person or an agent finds
        ;; a fixture again in the project list.
        (doseq [[kind items] [["bundles" bundles] ["generators" generators]]
                [i {:keys [project]}] (map-indexed vector items)
                :when (and (string? project)
                           (not (re-find #"^\d{8} \S.*: \S" project)))]
          (say "naming: %s[%d].project %s is not '<YYYYMMDD> <Area>: <what it shows>'; a dated, descriptive name tells the next reader what the files are for"
               kind i (pr-str project)))
        (if (seq @errs)
          (do (say "profile.yaml is not usable:")
              (doseq [m @errs] (say "  %s" m))
              (System/exit 1))
          {:text text
           :description (:description data)
           :users users
           :teams teams
           :bundles bundles
           :generators generators})))))

(defn- load-profile []
  (when-not (fs/exists? profile-path)
    (die 2 "no profile at %s" profile-path))
  (let [text (slurp (str profile-path) :encoding "UTF-8")
        data (try (yaml/parse-string text)
                  (catch Exception e
                    (refuse "profile.yaml is not valid YAML: %s" (ex-message e))))]
    (validate-profile text (plain data))))

;; ---------------------------------------------------------------- remote sources

(defn- url-encode-path [path]
  (->> (path-segments path)
       (map (fn [seg]
              (-> (URLEncoder/encode seg "UTF-8")
                  (str/replace "+" "%20"))))
       (str/join "/")))

(defn- github-headers []
  (let [token (System/getenv "GITHUB_TOKEN")]
    (cond-> {"User-Agent" "pdv-seed"
             "Accept" "application/vnd.github+json"}
      (not (str/blank? (str token))) (assoc "Authorization" (str "Bearer " token)))))

(defn- github-tree-oid
  "Resolve a path at a revision to its git object id."
  [{:keys [owner repo rev path]}]
  (let [url (str "https://api.github.com/repos/" owner "/" repo "/git/trees/" rev "?recursive=1")
        resp (try (http/get url {:headers (github-headers) :throw false :timeout 60000})
                  (catch Exception e
                    (die 2 "the GitHub API request for %s/%s failed: %s"
                         owner repo (ex-message e))))
        status (:status resp)
        body (try (json/parse-string (str (:body resp)))
                  (catch Exception _ nil))]
    (when-not (= 200 status)
      (die 2 "the GitHub API answered %s for %s/%s at %s: %s"
           status owner repo rev (or (get body "message") "no message")))
    (let [hit (some (fn [entry] (when (= path (get entry "path")) entry))
                    (get body "tree"))]
      (cond
        hit (or (get hit "sha") (get hit "oid"))
        (true? (get body "truncated"))
        (die 2 "the tree of %s/%s at %s is truncated and does not list %s, use a full commit sha"
             owner repo rev path)
        :else
        (die 2 "%s is not a file in %s/%s at %s" path owner repo rev)))))

(defn- head-status [url]
  (try
    (:status (http/head url {:throw false :timeout 20000}))
    (catch Exception _ nil)))

(defn- media-url [owner repo rev path]
  (str "https://media.githubusercontent.com/media/" owner "/" repo "/" rev "/"
       (url-encode-path path)))

(defn- raw-url [owner repo rev path]
  (str "https://raw.githubusercontent.com/" owner "/" repo "/" rev "/"
       (url-encode-path path)))

(defn- download-url
  "media serves an LFS object, raw serves the committed blob. Pick the one that answers."
  [owner repo rev path]
  (let [media (media-url owner repo rev path)
        media-status (head-status media)]
    (if (= 200 media-status)
      media
      (let [raw (raw-url owner repo rev path)
            raw-status (head-status raw)]
        (if (= 200 raw-status)
          raw
          (die 2 "cannot download %s/%s at %s path %s: media answered %s, raw answered %s"
               owner repo rev path media-status raw-status))))))

(defn- resolve-git
  "A git+ source resolves to the object id of its path and a cache key."
  [bundle probe?]
  (let [{:keys [owner repo rev path]} (:git bundle)
        oid (github-tree-oid (:git bundle))]
    {:source (:source bundle)
     :cache-key (str "github-" owner "-" repo "-" oid)
     :url (if probe?
            (download-url owner repo rev path)
            (media-url owner repo rev path))
     :sha256 nil}))

(defn- resolve-https [bundle]
  {:source (:source bundle)
   :cache-key (str "sha256-" (:sha256 bundle))
   :url (:url bundle)
   :sha256 (:sha256 bundle)})

(defn- resolve-remote
  "Resolve one remote-source bundle, memoized by source for this call."
  [seen bundle probe?]
  (or (get @seen (:source bundle))
      (let [resolved (case (:kind bundle)
                       :git (resolve-git bundle probe?)
                       :https (resolve-https bundle))]
        (swap! seen assoc (:source bundle) resolved)
        resolved)))

(defn- write-remote-index!
  "Hand the resolution to apply, so apply needs no second API call."
  [resolved]
  (fs/create-dirs (str seed-dir))
  (spit (str remote-index-path)
        (str (str/join "\n"
                       (map (fn [r]
                              (str/join "\t" [(:source r) (:cache-key r) (:url r)
                                              (or (:sha256 r) "-")]))
                            resolved))
             "\n")))

(def ^:private remote-index-cache (atom nil))

(defn- remote-index-entry [source]
  (when (nil? @remote-index-cache)
    (reset! remote-index-cache
            (if (fs/exists? remote-index-path)
              (into {}
                    (keep (fn [line]
                            (let [[src key url sha] (str/split line #"\t")]
                              (when (and src key url)
                                [src {:cache-key key
                                      :url url
                                      :sha256 (when (and sha (not= "-" sha)) sha)}]))))
                    (str/split-lines (slurp (str remote-index-path) :encoding "UTF-8")))
              {})))
  (get @remote-index-cache source))

;; ---------------------------------------------------------------- needs and hash

(defn- remote-bundles [profile]
  (filter #(not= :repo (:kind %)) (:bundles profile)))

(defn- cmd-needs []
  (let [profile (load-profile)
        repo-entries (distinct (concat (keep #(when (= :repo (:kind %)) (:relpath %))
                                             (:bundles profile))
                                       (map :dir (:generators profile))))
        seen (atom {})
        resolved (->> (remote-bundles profile)
                      (map #(resolve-remote seen % true))
                      (reduce (fn [acc r]
                                (if (some (fn [other] (= (:cache-key other) (:cache-key r))) acc)
                                  acc
                                  (conj acc r)))
                              []))]
    (doseq [rel repo-entries]
      (println (str "repo\t" rel)))
    (doseq [r resolved]
      (println (str "remote\t" (:cache-key r) "\t" (:url r) "\t" (or (:sha256 r) "-"))))
    (doseq [[i u] (map-indexed vector (:users profile))]
      (when-let [password-file (:password-file u)]
        (println (str "secret\t" i "\t" password-file))))
    (write-remote-index! resolved)
    (flush)))

(defn- staged-repo-files
  "Repository-relative path and absolute path of every staged file, sorted."
  []
  (if (fs/exists? repo-root)
    (->> (fs/glob repo-root "**")
         (filter fs/regular-file?)
         (map (fn [p] [(str (fs/relativize repo-root p)) p]))
         (sort-by first))
    []))

(defn- staged-remote-keys []
  (if (fs/exists? remote-root)
    (->> (fs/list-dir remote-root)
         (filter fs/regular-file?)
         (map (comp str fs/file-name))
         sort)
    []))

(defn- cmd-hash []
  (let [{:keys [text]} (load-profile)
        parts (concat [(str "profile\t" text)]
                      (map (fn [[rel p]] (str "file\t" rel "\t" (sha256-file p)))
                           (staged-repo-files))
                      (map (fn [k] (str "remote\t" k)) (staged-remote-keys)))]
    (println (sha256-string (str/join "\n" parts)))
    (flush)))

;; ---------------------------------------------------------------- nrepl client

(defn- ->str
  "bencode decodes strings as byte arrays."
  [v]
  (cond
    (nil? v) nil
    (string? v) v
    (bytes? v) (String. ^bytes v "UTF-8")
    :else (str v)))

(defn- nrepl-open []
  (let [sock (Socket.)]
    (try
      (.connect sock (InetSocketAddress. nrepl-host nrepl-port) 10000)
      (catch Exception e
        (die 2 "cannot reach the backend nREPL at %s:%s: %s"
             nrepl-host nrepl-port (ex-message e))))
    (.setSoTimeout sock nrepl-timeout-ms)
    {:socket sock
     :in (PushbackInputStream. (BufferedInputStream. (.getInputStream sock)))
     :out (BufferedOutputStream. (.getOutputStream sock))
     :id (atom 0)}))

(defn- nrepl-send! [{:keys [out id]} msg]
  (bencode/write-bencode out (assoc msg "id" (str (swap! id inc))))
  (.flush out))

(defn- nrepl-recv! [{:keys [in]}]
  (let [msg (try (bencode/read-bencode in)
                 (catch Exception e
                   (die 2 "the backend nREPL closed the connection: %s" (ex-message e))))]
    (when (nil? msg)
      (die 2 "the backend nREPL closed the connection"))
    msg))

(defn- nrepl-status [msg]
  (into #{} (keep ->str) (get msg "status")))

(defn- nrepl-await
  "Read responses until one reports done, forwarding out and err to stderr."
  [conn]
  (loop [acc []]
    (let [msg (nrepl-recv! conn)
          acc (conj acc msg)]
      (doseq [k ["out" "err"]]
        (when-let [text (->str (get msg k))]
          (binding [*out* *err*]
            (print (redact text))
            (flush))))
      (if (contains? (nrepl-status msg) "done")
        acc
        (recur acc)))))

(defn- nrepl-connect
  "Open a connection and clone one session, which carries the namespace state."
  []
  (let [conn (nrepl-open)]
    (nrepl-send! conn {"op" "clone"})
    (let [session (some (fn [msg] (->str (get msg "new-session"))) (nrepl-await conn))]
      (when (nil? session)
        (die 2 "the backend nREPL answered no session to clone"))
      (assoc conn :session session))))

(defn- nrepl-close! [{:keys [^Socket socket out session]}]
  (try
    (when session
      (bencode/write-bencode out {"op" "close" "id" "close" "session" session})
      (.flush out))
    (catch Exception _ nil))
  (try (.close socket) (catch Exception _ nil)))

(defn- nrepl-eval
  "Evaluate one form in the session and return every response it produced."
  [conn form]
  (nrepl-send! conn {"op" "eval"
                     "code" (pr-str form)
                     "session" (:session conn)})
  (nrepl-await conn))

(defn- nrepl-value
  "The value of one eval, refusing an error or an unreadable value."
  [msgs context]
  (let [failed (some #(contains? (nrepl-status %) "eval-error") msgs)
        ex (or (some #(->str (get % "ex")) msgs)
               (some #(->str (get % "root-ex")) msgs))
        value (last (keep #(->str (get % "value")) msgs))]
    (when (or failed (some? ex))
      (die 2 "%s failed: %s" context (truncate (redact (str (or ex "eval-error"))) 500)))
    (try
      (edn/read-string (str value))
      (catch Exception _
        (die 2 "%s returned a value this driver cannot read: %s"
             context (truncate (redact (str value)) 300))))))

(defn- load-engine! [conn]
  (when-not (fs/exists? engine-path)
    (die 2 "no seed engine at %s" engine-path))
  ;; load-string returns the file's last var, which EDN cannot read back.
  (nrepl-value (nrepl-eval conn (list 'do
                                      (list 'load-string (slurp (str engine-path) :encoding "UTF-8"))
                                      :loaded))
               "loading the seed engine")
  nil)

;; ---------------------------------------------------------------- apply

(defn- read-secret
  "The password staged for users[n], as JSON with a password field or as raw text."
  [n]
  (let [path (fs/path secret-root (str n))]
    (when-not (fs/exists? path)
      (die 2 "no staged secret at %s" path))
    (let [text (str/trim (slurp (str path) :encoding "UTF-8"))]
      (when (str/blank? text)
        (die 2 "the staged secret at %s is empty" path))
      (if (str/starts-with? text "{")
        (let [data (try (json/parse-string text)
                        (catch Exception _
                          (die 2 "the staged secret at %s is not JSON" path)))
              password (get data "password")]
          (if (non-blank-string? password)
            password
            (die 2 "the staged secret at %s has no password field" path)))
        text))))

(defn- effective-team [profile entry]
  (or (:team entry)
      (:name (first (:teams profile)))))

(defn- remote-staged-path [bundle]
  (let [resolved (or (remote-index-entry (:source bundle))
                     (resolve-remote (atom {}) bundle false))
        path (fs/path remote-root (:cache-key resolved))]
    (when-not (fs/exists? path)
      (die 2 "no staged download at %s for %s" path (:source bundle)))
    (when (lfs-pointer? path)
      (die 2 "the staged download at %s is a git LFS pointer, so the host resolved no object"
           path))
    path))

(defn- bundle-request [profile bundle]
  (let [staged (case (:kind bundle)
                 :repo (let [path (fs/path repo-root (:relpath bundle))]
                         (when-not (fs/exists? path)
                           (die 2 "no staged bundle at %s for %s" path (:source bundle)))
                         path)
                 :git (remote-staged-path bundle)
                 :https (remote-staged-path bundle))
        digest (sha256-file staged)]
    (when (and (:sha256 bundle) (not= (:sha256 bundle) digest))
      (die 2 "%s declares sha256 %s but the staged file hashes to %s"
           (:source bundle) (:sha256 bundle) digest))
    {:path (str staged)
     :source (:source bundle)
     :sha256 digest
     :team (effective-team profile bundle)
     :project (:project bundle)}))

(defn- generator-request [profile generator]
  (let [script (fs/path repo-root (:script generator))]
    (when-not (fs/exists? script)
      (die 2 "no staged generator at %s" script))
    {:script (str script)
     :args (or (:args generator) {})
     :team (effective-team profile generator)
     :project (:project generator)}))

(defn- agent-user [profile]
  (first (filter :agent? (:users profile))))

(defn- clean-email
  "The engine stores emails normalised, so compare the same way."
  [email]
  (-> (str email)
      str/trim
      str/lower-case
      (str/replace #"^mailto:" "")
      (str/replace #"^<(.*)>$" "$1")
      str/trim))

(defn- find-token
  "A token for email, in a map keyed by email or a map of tokens."
  [x email]
  (let [wanted (clean-email email)]
    (cond
      (map? x)
      (or (some (fn [[k v]]
                  (cond
                    (not (or (keyword? k) (string? k))) nil
                    (not= wanted (clean-email (name k))) nil
                    (string? v) v
                    :else (find-token v email)))
                x)
          (when (= wanted (clean-email (:email x)))
            (let [token (or (:token x) (:access-token x))]
              (when (string? token) token)))
          (some (fn [v] (when-not (string? v) (find-token v email))) (vals x)))
      (sequential? x) (some #(find-token % email) x)
      :else nil)))

(defn- token-of
  "The access token for email, whatever shape the engine's :secrets takes."
  [secrets email]
  (let [named (some (fn [[k v]]
                      (when (and (string? v)
                                 (or (keyword? k) (string? k))
                                 (str/includes? (str/lower-case (name k)) "token"))
                        v))
                    (when (map? secrets) secrets))]
    (or (find-token secrets email)
        named
        (when (string? secrets) secrets)
        (some (fn [v] (when (string? v) v))
              (when (map? secrets) (vals secrets))))))

(defn- write-agent-json! [profile secrets database]
  (let [file (fs/path out-root "agent.json")]
    (fs/create-dirs (str out-root))
    (if-let [agent (agent-user profile)]
      (let [token (or (token-of secrets (:email agent)) "")
            url (or (System/getenv "PENPOT_PUBLIC_URI") "")]
        (when (str/blank? url)
          (say "warning: PENPOT_PUBLIC_URI is unset, so agent.json carries an empty url"))
        (when (str/blank? token)
          (say "warning: the seed engine returned no token for %s" (:email agent)))
        (swap! secret-values conj token)
        (let [payload {"url" url
                       "email" (:email agent)
                       "token" token
                       "database" database}
              perms (PosixFilePermissions/asFileAttribute
                     (PosixFilePermissions/fromString "rw-------"))]
          (fs/delete-if-exists file)
          (Files/createFile file (into-array FileAttribute [perms]))
          (spit (str file) (str (json/generate-string payload) "\n"))))
      (when (fs/exists? file)
        (fs/delete file)))))

(defn- cmd-apply [opts]
  (let [slug (get opts "slug")
        hash (get opts "hash")
        database (get opts "database")
        profile-name (get opts "profile")]
    (when (nil? slug) (refuse "apply needs --slug"))
    (when-not (re-matches slug-re slug)
      (refuse "--slug must be 1 to 40 of a-z, 0-9 and _"))
    (when (nil? hash) (refuse "apply needs --hash"))
    (when-not (re-matches hash-re hash)
      (refuse "--hash must be 64 hex digits"))
    (when (and (some? profile-name)
               (not (re-matches profile-name-re profile-name)))
      (refuse "--profile must be 1 to 64 of A-Z, a-z, 0-9, . _ and -"))
    (let [database (or database (str "pdvwt_" slug))]
      (when-not (re-matches database-re database)
        (refuse "--database must be 1 to 63 of a-z, 0-9, _ and -"))
      (let [profile (load-profile)
            users' (:users profile)
            request (cond-> {:slug slug
                             :hash hash
                             :users (mapv (fn [i user]
                                            (let [password (or (if (:password-file user)
                                                                 (read-secret i)
                                                                 (:password user))
                                                               default-password)]
                                              (swap! secret-values conj password)
                                              {:email (:email user)
                                               :fullname (:fullname user)
                                               :password password
                                               :agent? (:agent? user)}))
                                          (range) users')
                             :teams (mapv (fn [team]
                                            {:name (:name team)
                                             :members (mapv (fn [member]
                                                              {:email (:email member)
                                                               :role (:role member)})
                                                            (:members team))})
                                          (:teams profile))
                             :bundles (mapv #(bundle-request profile %) (:bundles profile))
                             :generators (mapv #(generator-request profile %) (:generators profile))}
                      (some? profile-name) (assoc :profile profile-name))
            conn (nrepl-connect)]
        (try
          (load-engine! conn)
          (let [result (nrepl-value (nrepl-eval conn (list 'pdv.seed/seed! request)) "seeding")]
            (when-not (map? result)
              (die 2 "the seed engine returned %s instead of a map" (pr-str (type result))))
            (write-agent-json! profile (:secrets result) database)
            (println (pr-str (dissoc result :secrets)))
            (flush)
            (say "seeded %s into %s: %s users, %s teams, %s files, schema %s"
                 slug database
                 (count (:users profile)) (count (:teams profile))
                 (count (:files result)) (or (:schema-head result) "-")))
          (finally (nrepl-close! conn)))))))

;; ---------------------------------------------------------------- status and export

(defn- meta-value [meta & keys]
  (some (fn [k] (when (contains? meta k) (get meta k))) keys))

(defn- print-status [{:keys [meta files]}]
  (let [meta (or meta {})
        files (or files [])]
    (println (str "profile:  " (or (meta-value meta :profile) "none")))
    (println (str "hash:     " (or (meta-value meta :input_hash :input-hash) "-")))
    (println (str "seeded:   " (or (meta-value meta :seeded_at :seeded-at) "-")))
    (println (str "schema:   " (or (meta-value meta :schema_head :schema-head) "-")))
    (when-let [worktree (meta-value meta :worktree_path :worktree-path)]
      (println (str "worktree: " worktree)))
    (println (str "files:    " (count files)))
    (doseq [f files]
      (let [ids (:file-ids f)]
        (println (str "  " (or (:source f) "-")
                      "  " (if (sequential? ids) (count ids) 0) " file(s)"
                      "  project " (or (:project f) "-")))))))

(defn- cmd-status []
  (let [conn (nrepl-connect)]
    (try
      (load-engine! conn)
      (let [result (nrepl-value (nrepl-eval conn (list 'pdv.seed/status)) "reading the seed status")]
        (when-not (map? result)
          (die 2 "status returned %s instead of a map" (pr-str (type result))))
        (print-status result)
        (flush))
      (finally (nrepl-close! conn)))))

(defn- cmd-export [opts]
  (let [team (get opts "team")
        project (get opts "project")
        out (get opts "out")]
    (when (nil? team) (refuse "export needs --team"))
    (when (nil? project) (refuse "export needs --project"))
    (when (nil? out) (refuse "export needs --out"))
    (when-not (str/ends-with? out ".penpot")
      (refuse "--out must end in .penpot"))
    (fs/create-dirs (str (fs/parent (fs/path out))))
    (let [conn (nrepl-connect)]
      (try
        (load-engine! conn)
        (let [result (nrepl-value
                      (nrepl-eval conn (list 'pdv.seed/export-bundle!
                                             {:team team :project project :out out}))
                      "exporting the bundle")]
          (println (pr-str result))
          (flush))
        (finally (nrepl-close! conn))))))

;; ---------------------------------------------------------------- entry

(defn- usage [code]
  (binding [*out* *err*]
    (println "usage: pdv-seed.bb <command> [flags]")
    (println "  needs                                   print what the host must stage")
    (println "  hash                                    print the input hash of the staged tree")
    (println "  apply --slug S --hash H [--database D] [--profile NAME]")
    (println "                                           seed the running backend")
    (println "  status                                  print what the backend holds")
    (println "  export --team T --project P --out FILE   export a project as one bundle")
    (flush))
  (System/exit code))

(defn- parse-opts [args allowed]
  (loop [args (vec args)
         opts {}]
    (if-let [arg (first args)]
      (if (str/starts-with? arg "--")
        (let [flag (subs arg 2)]
          (when-not (contains? allowed flag)
            (refuse "unknown flag --%s" flag))
          (let [value (second args)]
            (when (or (nil? value) (str/starts-with? value "--"))
              (refuse "--%s needs a value" flag))
            (recur (subvec args 2) (assoc opts flag value))))
        (refuse "unexpected argument %s" arg))
      opts)))

(defn- no-args! [args]
  (when (seq args)
    (refuse "this command takes no flags, not %s" (str/join " " args))))

(defn- -main [args]
  (let [[command & rest] args]
    (case command
      "needs" (do (no-args! rest) (cmd-needs))
      "hash" (do (no-args! rest) (cmd-hash))
      "apply" (cmd-apply (parse-opts rest #{"slug" "hash" "database" "profile"}))
      "status" (do (no-args! rest) (cmd-status))
      "export" (cmd-export (parse-opts rest #{"team" "project" "out"}))
      (usage 1))))

(try
  (-main *command-line-args*)
  (catch Throwable t
    (say "internal error: %s" (or (ex-message t) (str t)))
    (System/exit 2)))
