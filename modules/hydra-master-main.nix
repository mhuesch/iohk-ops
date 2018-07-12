{ resources, config, pkgs, lib, nodes, ... }:

with lib;

let
  commonBuildMachineOpt = {
    speedFactor = 1;
    sshKey = "/etc/nix/id_buildfarm";
    sshUser = "root";
    system = "x86_64-linux";
    supportedFeatures = [ "kvm" "nixos-test" ];
  };
  mkLinux = hostName: commonBuildMachineOpt // {
    inherit hostName;
    maxJobs = 4;
  };
  mkMac = hostName: commonBuildMachineOpt // {
    inherit hostName;
    maxJobs = 2;
    system = "x86_64-darwin";
    sshUser = "builder";
    supportedFeatures = [];
  };

  cleanIp = host: let
      ip1 = if nodes.${host}.options.networking.publicIPv4.isDefined then nodes.${host}.config.networking.publicIPv4 else "0.0.0.0";
    in
      if ip1 == null then "0.0.0.0" else ip1;
in {
  environment.etc = lib.singleton {
    target = "nix/id_buildfarm";
    source = ../static/id_buildfarm;
    uid = config.ids.uids.hydra;
    gid = config.ids.gids.hydra;
    mode = "0440";
  };

  nix = {
    distributedBuilds = true;
    buildMachines = [
      (mkLinux (cleanIp "hydra-build-slave-1"))
      (mkLinux (cleanIp "hydra-build-slave-2"))
      (mkMac "osx-1.aws.iohkdev.io")
      (mkMac "osx-2.aws.iohkdev.io")
      (mkMac "osx-3.aws.iohkdev.io")
    ];
  };

  services.hydra = {
    hydraURL = "https://hydra.iohk.io";
    # max output is 4GB because of amis
    # auth token needs `repo:status`
    extraConfig = ''
      max_output_size = 4294967296

      store_uri = s3://iohk-nix-cache?secret-key=/etc/nix/hydra.iohk.io-1/secret&log-compression=br&region=eu-central-1
      server_store_uri = https://iohk-nix-cache.s3-eu-central-1.amazonaws.com/
      binary_cache_public_uri = https://iohk-nix-cache.s3-eu-central-1.amazonaws.com/
      log_prefix = https://iohk-nix-cache.s3-eu-central-1.amazonaws.com/
      upload_logs_to_binary_cache = true

      <github_authorization>
        input-output-hk = ${builtins.readFile ../static/github_token}
      </github_authorization>
      <githubstatus>
        jobs = serokell:iohk-nixops.*
        inputs = jobsets
        excludeBuildFromContext = 1
      </githubstatus>
      <githubstatus>
        jobs = serokell:cardano.*
        inputs = cardano
        excludeBuildFromContext = 1
      </githubstatus>
      <githubstatus>
        jobs = serokell:daedalus.*:tests\..*
        inputs = daedalus
        excludeBuildFromContext = 1
      </githubstatus>
      <githubstatus>
        jobs = serokell:plutus.*:tests\..*
        inputs = plutus
        excludeBuildFromContext = 1
      </githubstatus>
    '';
  };

  security.acme.certs = {
    "hydra.iohk.io" = {
      email = "info@iohk.io";
      user = "nginx";
      group = "nginx";
      webroot = config.security.acme.directory + "/acme-challenge";
      postRun = "systemctl reload nginx.service";
    };
  };

  services.nginx = {
    httpConfig = ''
      server_names_hash_bucket_size 64;

      keepalive_timeout   70;
      gzip            on;
      gzip_min_length 1000;
      gzip_proxied    expired no-cache no-store private auth;
      gzip_types      text/plain application/xml application/javascript application/x-javascript text/javascript text/xml text/css;

      server {
        server_name _;
        listen 80;
        listen [::]:80;
        location /.well-known/acme-challenge {
          root ${config.security.acme.certs."hydra.iohk.io".webroot};
        }
        location / {
          return 301 https://$host$request_uri;
        }
      }

      server {
        listen 443 ssl spdy;
        server_name hydra.iohk.io;

        ssl_certificate /var/lib/acme/hydra.iohk.io/fullchain.pem;
        ssl_certificate_key /var/lib/acme/hydra.iohk.io/key.pem;

        location / {
          proxy_pass http://127.0.0.1:8080;
          proxy_set_header Host $http_host;
          proxy_set_header REMOTE_ADDR $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto https;
        }
        location ~ /(nix-cache-info|.*\.narinfo|nar/*) {
          return 301 https://iohk-nix-cache.s3-eu-central-1.amazonaws.com$request_uri;
        }
      }
    '';
  };
}
