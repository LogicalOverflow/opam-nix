# Pkgset = { ${name} = { ${version} = Pkgdef; ... } ... }
# Pkgdef = { name = String; version = String; depends = [OpamVar]; build = ?[[String]]; install = ?[[String]]; ... }

args:
let
  inherit (builtins)
    readDir mapAttrs concatStringsSep isString isList attrValues filter head
    foldl' fromJSON listToAttrs readFile toFile isAttrs pathExists toJSON
    deepSeq length sort concatMap attrNames;
  bootstrapPackages = args.pkgs;
  inherit (bootstrapPackages) lib;
  inherit (lib)
    splitString tail nameValuePair zipAttrsWith collect concatLists
    filterAttrsRecursive fileContents pipe makeScope optionalAttrs hasSuffix
    converge mapAttrsRecursive composeManyExtensions removeSuffix optionalString
    last init recursiveUpdate foldl optional optionals importJSON;

  inherit (import ./evaluator lib) compareVersions';

  readDirRecursive = dir:
    mapAttrs (name: type:
      if type == "directory" then readDirRecursive "${dir}/${name}" else type)
    (readDir dir);

  # [Pkgset] -> Pkgset
  mergePackageSets = zipAttrsWith (_: foldl' (a: b: a // b) { });

  inherit (bootstrapPackages)
    runCommandNoCC linkFarm symlinkJoin runCommand opam2json lndir-level opam;

  # Pkgdef -> Derivation
  builder = import ./builder.nix bootstrapPackages.lib;

  contentAddressedIFD = dir:
    deepSeq (readDir dir) (/. + builtins.unsafeDiscardStringContext dir);

  global-variables =
    import ./global-variables.nix bootstrapPackages.stdenv.hostPlatform;

  defaultEnv = { inherit (global-variables) os os-family os-distribution; };

  mergeSortVersions = zipAttrsWith (_: sort (compareVersions' "lt"));

  readFileContents = { files ? bootstrapPackages.emptyDirectory, ... }@def:
    (builtins.removeAttrs def [ "files" ]) // {
      files-contents =
        mapAttrs (name: _: readFile (files + "/${name}")) (readDir files);
    };

  writeFileContents = { name ? "opam", files-contents ? { }, ... }@def:
    (builtins.removeAttrs def [ "files-contents" ])
    // optionalAttrs (files-contents != { }) {
      files = symlinkJoin {
        name = "${name}-files";
        paths =
          (attrValues (mapAttrs bootstrapPackages.writeTextDir files-contents));
      };
    };

  eraseStoreReferences = def:
    (builtins.removeAttrs def [ "repo" "opamFile" "src" ])
    // optionalAttrs (def ? src.url) {
      # Keep srcs which can be fetched
      src = {
        inherit (def.src) url rev subdir;
        hash = def.src.narHash;
      };
    };

  # Note: there can only be one version of the package present in packagedefs we're working on
  injectSources = sourceMap: def:
    if sourceMap ? ${def.name} then
      def // { src = sourceMap.${def.name}; }
    else if def ? src then
      def // {
        src = (bootstrapPackages.fetchgit { inherit (def.src) url rev hash; })
          + def.src.subdir;
      }
    else
      def;

  isImpure = builtins ? currentSystem;

  namePathPair = name: path: { inherit name path; };
in rec {

  splitNameVer = nameVer:
    let nv = nameVerToValuePair nameVer;
    in {
      inherit (nv) name;
      version = nv.value;
    };

  nameVerToValuePair = nameVer:
    let split = splitString "." nameVer;
    in nameValuePair (head split) (concatStringsSep "." (tail split));

  # Path -> {...}
  importOpam = opamFile:
    let
      json = runCommandNoCC "opam.json" {
        preferLocalBuild = true;
        allowSubstitutes = false;
      } "${opam2json}/bin/opam2json ${opamFile} > $out";
    in fromJSON (readFile json);

  fromOpam = opamText: importOpam (toFile "opam" opamText);

  # Path -> Derivation
  opam2nix =
    { src, opamFile ? src + "/${name}.opam", name ? null, version ? null }:
    builder ({ inherit src name version; } // importOpam opamFile);

  listRepo = repo:
    mergeSortVersions (map (p: listToAttrs [ (nameVerToValuePair p) ])
      (concatMap attrNames
        (attrValues (readDirRecursive (repo + "/packages")))));

  opamListToQuery = list: listToAttrs (map nameVerToValuePair list);

  opamList = repo:
    { env ? defaultEnv, depopts ? true, best-effort ? false, dev ? false
    , with-test ? false, with-doc ? false }:
    packages:
    let
      pkgRequest = name: version:
        if version == "*" then
          name
        else if isNull version then
          (lib.warn ''
            [opam-nix] Using `null' as a version in a query is deprecated, because it is unintuitive to the user. Use `"*"' instead.''
            name)
        else
          "${name}.${version}";

      toString' = x: if isString x then x else toJSON x;

      environment = concatStringsSep ","
        (attrValues (mapAttrs (name: value: "${name}=${toString' value}") env));

      query = concatStringsSep "," (attrValues (mapAttrs pkgRequest packages));

      resolve-drv = runCommandNoCC "resolve" {
        nativeBuildInputs = [ opam bootstrapPackages.ocaml ];
        OPAMCLI = "2.0";
      } ''
        export OPAMROOT=$NIX_BUILD_TOP/opam

        cd ${repo}
        opam admin list \
          --resolve=${query} \
          --short \
          --columns=package \
          ${optionalString depopts "--depopts"} \
          ${optionalString dev "--dev"} \
          ${optionalString with-test "--with-test"} \
          ${optionalString with-doc "--doc"} \
          ${optionalString best-effort "--best-effort"} \
          ${optionalString (!isNull env) "--environment '${environment}'"} \
          --keep-default-environment \
          | tee $out
      '';
      solution = fileContents resolve-drv;

      lines = s: splitString "\n" s;

    in lines solution;

  makeOpamRepo' = recursive: dir:
    let
      contents = readDir dir;
      files = if recursive then
        readDirRecursive dir
      else
        (contents // optionalAttrs (contents.opam or null == "directory") {
          opam = readDir "${dir}/opam";
        });
      opamFiles = filterAttrsRecursive
        (name: value: isAttrs value || hasSuffix "opam" name) files;
      opamFilesOnly =
        converge (filterAttrsRecursive (_: v: v != { })) opamFiles;
      packages = concatLists (collect isList (mapAttrsRecursive
        (path': _: [rec {
          fileName = last path';
          dirName =
            splitNameVer (if init path' != [ ] then last (init path') else "");
          parsedOPAM = fromOpam opamFileContents;
          name = parsedOPAM.name or (if hasSuffix ".opam" fileName then
            removeSuffix ".opam" fileName
          else
            dirName.name);

          version = parsedOPAM.version or (if dirName.version != "" then
            dirName.version
          else
            "dev");
          subdir = "/" + concatStringsSep "/" (let i = init path';
          in if length i > 0 && last i == "opam" then init i else i);
          source = dir + subdir;
          opamFile = "${dir + ("/" + (concatStringsSep "/" path'))}";
          opamFileContents = readFile opamFile;
        }]) opamFilesOnly));
      repo-description =
        namePathPair "repo" (toFile "repo" ''opam-version: "2.0"'');
      opamFileLinks = map ({ name, version, opamFile, ... }:
        namePathPair "packages/${name}/${name}.${version}/opam" opamFile)
        packages;
      pkgdefs = foldl (acc: x:
        recursiveUpdate acc { ${x.name} = { ${x.version} = x.parsedOPAM; }; })
        { } packages;
      sourceMap = foldl (acc: x:
        recursiveUpdate acc {
          ${x.name} = {
            ${x.version} = (optionalAttrs (builtins.isAttrs dir) dir) // {
              inherit (x) subdir;
              outPath = contentAddressedIFD x.source;
            };
          };
        }) { } packages;
      repo = linkFarm "opam-repo" ([ repo-description ] ++ opamFileLinks);
    in repo // { passthru = { inherit sourceMap pkgdefs; }; };

  makeOpamRepo = makeOpamRepo' false;
  makeOpamRepoRec = makeOpamRepo' true;

  filterOpamRepo = packages: repo:
    linkFarm "opam-repo" ([ (namePathPair "repo" "${repo}/repo") ] ++ attrValues
      (mapAttrs (name: version:
        let
          defaultPath = "${repo}/packages/${name}/${
              head (attrNames (readDir "${repo}/packages/${name}"))
            }";
        in if version == "*" || isNull version then
          namePathPair "packages/${name}/${name}.dev" defaultPath
        else
          namePathPair "packages/${name}/${name}.${version}"
          (let path = "${repo}/packages/${name}/${name}.${version}";
          in if builtins.pathExists path then path else defaultPath)) packages))
    // optionalAttrs (repo ? passthru) {
      passthru = let
        pickRelevantVersions = from:
          mapAttrs (name: version: {
            ${if version == "*" || isNull version then "dev" else version} =
              if version == "*" || isNull version then
                head (attrValues from.${name})
              else
                from.${name}.${version} or (head (attrValues from.${name}));
          }) packages;
      in repo.passthru // mapAttrs (_: pickRelevantVersions) {
        inherit (repo.passthru) sourceMap pkgdefs;
      };

    };

  queryToDefs = repos: packages:
    let
      findPackage = name: version:
        let
          pkgDir = repo: repo + "/packages/${name}/${name}.${version}";
          filesPath = contentAddressedIFD (pkgDir repo + "/files");
          repos' = filter (repo:
            repo ? passthru.pkgdefs.${name}.${version}
            || pathExists (pkgDir repo)) repos;
          repo = if length repos' > 0 then
            head repos'
          else
            throw "Could not find package ${name}.${version}";
          isLocal = repo ? passthru.sourceMap;
        in {
          opamFile = pkgDir repo + "/opam";
          inherit name version isLocal repo;
        } // optionalAttrs (pathExists (pkgDir repo + "/files")) {
          files = filesPath;
        } // optionalAttrs isLocal {
          src = repo.passthru.sourceMap.${name}.${version};
          pkgdef = repo.passthru.pkgdefs.${name}.${version};
        };

      packageFiles = mapAttrs findPackage packages;
    in mapAttrs (_:
      { opamFile, name, version, ... }@args:
      (builtins.removeAttrs args [ "pkgdef" ])
      // args.pkgdef or (importOpam opamFile)) packageFiles;

  callPackageWith = autoArgs: fn: args:
    let
      f = if lib.isAttrs fn then
        fn
      else if lib.isFunction fn then
        fn
      else
        import fn;
      auto =
        builtins.intersectAttrs (f.__functionArgs or (builtins.functionArgs f))
        autoArgs;
    in lib.makeOverridable f (auto // args);

  defsToScope = pkgs: defs:
    makeScope callPackageWith (self:
      (mapAttrs (name: pkg: self.callPackage (builder pkg) { }) defs) // {
        nixpkgs = pkgs.extend (_: _: { inherit opam2json; });
      });

  defaultOverlay = import ./overlays/ocaml.nix;
  staticOverlay = import ./overlays/ocaml-static.nix;
  darwinOverlay = import ./overlays/ocaml-darwin.nix;
  opamRepository = args.opam-repository;

  __overlays = [
    (final: prev:
      defaultOverlay final prev
      // optionalAttrs prev.nixpkgs.stdenv.hostPlatform.isStatic
      (staticOverlay final prev)
      // optionalAttrs prev.nixpkgs.stdenv.hostPlatform.isDarwin
      (darwinOverlay final prev))
  ];

  applyOverlays = overlays: scope:
    scope.overrideScope' (composeManyExtensions overlays);

  symlinkJoinLevel =
    args_@{ name
         , paths
         , level
         , preferLocalBuild ? true
         , allowSubstitutes ? false
         , postBuild ? ""
         , ...
         }:
    let
      args = removeAttrs args_ [ "name" "postBuild" ]
        // {
          inherit preferLocalBuild allowSubstitutes;
          passAsFile = [ "paths" ];
        }; # pass the defaults
    in runCommand name args
      ''
        mkdir -p $out
        for i in $(cat $pathsPath); do
          ${lndir-level}/bin/lndir -level ${toString level} -silent "$i" "$out"
        done
        ${postBuild}
      '';

  joinRepos' = level: repos:
    if length repos == 1 then
      head repos
    else
      symlinkJoinLevel {
        name = "opam-repo";
        paths = repos;
        inherit level;
      };

  joinRepos = joinRepos' 2;
  joinReposOverridePackages = joinRepos' 1;

  materialize =
    { repos ? [ opamRepository ], resolveArgs ? { }, regenCommand ? null }:
    query:
    pipe query [
      (opamList (joinRepos repos) resolveArgs)
      (opamListToQuery)
      (queryToDefs repos)

      (mapAttrs (_: eraseStoreReferences))
      (mapAttrs (_: readFileContents))
      (d: d // { __opam_nix_regen = regenCommand; })
      (toJSON)
      (toFile "package-defs.json")
    ];

  materializeOpamProject = { repos ? [ opamRepository ]
    , resolveArgs ? { dev = true; }, regenCommand ? null, pinDepends ? true
    , recursive ? false }:
    name: project: query:
    let
      repo = makeOpamRepo' recursive project;
      latestVersions = mapAttrs (_: last) (listRepo repo);

      pinDeps =
        getPinDepends repo.passthru.pkgdefs.${name}.${latestVersions.${name}};
    in materialize {
      repos = [ repo ] ++ optionals pinDepends pinDeps ++ repos;
      inherit resolveArgs regenCommand;
    } ({ ${name} = latestVersions.${name}; } // query);

  materializedDefsToScope =
    { pkgs ? bootstrapPackages, sourceMap ? { }, overlays ? __overlays }:
    defs:
    pipe defs [
      (readFile)
      (fromJSON)
      (d: removeAttrs d [ "__opam_nix_regen" ])
      (mapAttrs (_: writeFileContents))
      (mapAttrs (_: injectSources sourceMap))

      (defsToScope pkgs)
      (applyOverlays overlays)
    ];

  queryToScope = { repos ? [ opamRepository ], pkgs ? bootstrapPackages
    , overlays ? __overlays, resolveArgs ? { } }:
    query:
    pipe query [
      (opamList (joinRepos repos) resolveArgs)
      (opamListToQuery)
      (queryToDefs repos)
      (defsToScope pkgs)
      (applyOverlays overlays)
    ];

  opamImport = { repos ? [ opamRepository ], pkgs ? bootstrapPackages
    , overlays ? __overlays }:
    export:
    let installedList = (importOpam export).installed;
    in pipe installedList [
      opamListToQuery
      (queryToDefs repos)
      (defsToScope pkgs)
      (applyOverlays overlays)
    ];

  getPinDepends = pkgdef:
    if pkgdef ? pin-depends then
      map (dep:
        let
          inherit (splitNameVer (head dep)) name version;

          fullUrl = (last dep);
          baseUrl = last (splitString "+" fullUrl); # Get rid of "git+"
          urlParts = splitString "#" baseUrl;
          url = head urlParts;
          ref = last urlParts;
          hasRef = length urlParts > 1;
          isRev = s: !isNull (builtins.match "[0-9a-f]{40}" s);
          hasRev = hasRef && isRev ref;
          optionalRev = optionalAttrs hasRev { rev = ref; };
          refsOrWarn = if hasRef && !isRev ref then {
            inherit ref;
          } else if lib.versionAtLeast __nixVersion "2.4" then {
            allRefs = true;
          } else
            lib.warn
            "[opam-nix] Nix version is too old for allRefs = true; fetching a repository may fail if the commit is on a non-master branch"
            { };
          path =
            (builtins.fetchGit ({ inherit url; } // refsOrWarn // optionalRev))
            // {
              inherit url;
            };
          repo = filterOpamRepo { ${name} = version; } (makeOpamRepo path);
        in if !hasRev && !isImpure then
          lib.warn
          "[opam-nix] pin-depends without an explicit sha1 is not supported in pure evaluation mode; try with --impure"
          bootstrapPackages.emptyDirectory
        else
          repo) pkgdef.pin-depends
    else
      [ ];

  buildOpamProject = { repos ? [ opamRepository ], pkgs ? bootstrapPackages
    , overlays ? __overlays, resolveArgs ? { dev = true; }, pinDepends ? true
    , recursive ? false }@args:
    name: project: query:
    let
      repo = makeOpamRepo' recursive project;
      latestVersions = mapAttrs (_: last) (listRepo repo);

      pinDeps =
        getPinDepends repo.passthru.pkgdefs.${name}.${latestVersions.${name}};
    in queryToScope {
      repos = [ repo ] ++ optionals pinDepends pinDeps ++ repos;
      overlays = overlays;
      inherit pkgs resolveArgs;
    } ({ ${name} = latestVersions.${name}; } // query);

  buildOpamProject' = { repos ? [ opamRepository ], pkgs ? bootstrapPackages
    , overlays ? __overlays, resolveArgs ? { dev = true; }, pinDepends ? true
    , recursive ? false }@args:
    project: query:
    let
      repo = makeOpamRepo' recursive project;
      latestVersions = mapAttrs (_: last) (listRepo repo);

      pinDeps = concatLists (attrValues (mapAttrs
        (name: version: getPinDepends repo.passthru.pkgdefs.${name}.${version})
        latestVersions));
    in queryToScope {
      repos = [ repo ] ++ optionals pinDepends pinDeps ++ repos;
      overlays = overlays;
      inherit pkgs resolveArgs;
    } (latestVersions // query);

  buildDuneProject =
    { pkgs ? bootstrapPackages, dune ? pkgs.pkgsBuildBuild.dune_3, ... }@args:
    name: project: query:
    let
      generatedOpamFile = pkgs.pkgsBuildBuild.stdenv.mkDerivation {
        name = "${name}.opam";
        src = project;
        nativeBuildInputs = [ dune pkgs.pkgsBuildBuild.ocaml ];
        phases = [ "unpackPhase" "buildPhase" "installPhase" ];
        buildPhase = "dune build ${name}.opam";
        installPhase = ''
          rm _build -rf
          cp -R . $out
        '';
      };
    in buildOpamProject args name generatedOpamFile query;
}
