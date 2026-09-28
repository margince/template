Test stubs for the host adapter. Not used in a deployment.

Put this directory first on PATH. Every stub reads and writes files in
$STUB_STATE (required). host.test.sh, bootstrap.test.sh and lifecycle tests
use them; no network, server, or registry is contacted.

ssh      Checks the options the adapter must pass (BatchMode=yes,
         StrictHostKeyChecking=yes, a UserKnownHostsFile of mode 600, an
         identity file of mode 600 when -i is given), appends its arguments
         to $STUB_STATE/ssh.log, then runs the remote command locally with
         `sh -c` in $STUB_SERVER_ROOT. When STUB_SERVER_ROOT is set, every
         "/opt/margince" in the command becomes "$STUB_SERVER_ROOT/opt/margince",
         so the default HOST_DIR lands in the scratch server. Standard input
         is passed through. $STUB_STATE/fail.ssh makes it exit 255. The
         command runs with server/ first on PATH (see server/mv).
scp      The same option checks; appends its arguments to scp.log; copies
         with `cp -Rp` (the same directory semantics as `scp -r`), with the
         same path rewrite for the host:path target.
docker   Appends each call's arguments to docker.log (one line). Operations:
         version, login, manifest, compose-version, compose-<sub> (pull, up,
         down, ps), compose-exec-<service>. An operation fails (exit 1) when
         $STUB_STATE/fail.<op> exists and is empty, or when the call's
         arguments contain one of its lines; or while
         $STUB_STATE/fail-times.<op> holds a number above 0 (decremented per
         call). Each call also appends "<op> DOCKER_CONFIG=<value>" to
         docker-env.log. `login` saves its standard input to login.stdin and
         writes a stand-in config.json into $DOCKER_CONFIG (or, when it is
         unset, $STUB_STATE/home-docker, never the real home directory).
         `compose version` prints $STUB_STATE/compose-version (default
         2.30.0). `compose ps` prints $STUB_STATE/ps-services (default
         api web worker caddy, one per line). `ps` (docker ps) prints
         $STUB_STATE/docker-ps (default nothing).
curl     Appends its arguments to curl.log and prints $STUB_STATE/curl-code
         (default 200). $STUB_STATE/fail.curl prints 000 and exits 7.
timeout  Drops the duration and runs the rest.
server/mv  On the stub server only: GNU mv when available; otherwise
         `mv -T <src> <dst>` is emulated (remove <dst>, then rename), because
         macOS mv has no -T. The real servers (Ubuntu, Amazon Linux) have GNU mv.

bootstrap/ssh  For bootstrap.test.sh: the same option checks, and answers the
         bootstrap's commands from files instead of running them:
         `cat /etc/os-release` prints $STUB_STATE/os-release;
         `docker compose version --short` prints $STUB_STATE/compose-version
         or fails when it is absent; `id -nG` prints $STUB_STATE/groups;
         `dpkg-query -W ...` prints $STUB_STATE/dpkg (lines "ii <package>";
         empty when absent);
         `sh -s` appends standard input to scripts.log and then writes 2.39.4
         to compose-version (the install worked) unless fail.install exists;
         a command with `usermod -aG docker` appends " docker" to groups.
