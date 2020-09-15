<p align="center">
  <img src="https://user-images.githubusercontent.com/3843505/92512260-26878d80-f1d4-11ea-944d-73f3387f74e2.png" width="150" height="150" alt="sampo">
  <br>
  <strong>A shell script API server for running your shell scripts.</strong>
</p>

```
joukahainen:~$ curl -i http://localhost:1042/echo/rusty-fork
HTTP/1.1 200 OK
Date: Sun, 06 Sep 2020 16:54:45 UTC
Version: HTTP/1.1
Accept: text/plain
Accept-Language: en-US
Server: sampo/1.0.0
Content-Type: text/plain

rusty-fork
```

# How It Works

The `sampo` Kubernetes Deployment runs a `sampo` container, which is running a shell script that processes your API calls.  Each endpoint can call any arbitrary shell code.

You can run `sampo` directly in your shell, but it works best in Kubernetes.

# Details

Details can be found on [this blog post](https://jacobsalmela.com/2020/09/15/introducing-sampo-a-bash-api-server-that-runs-your-shell-scripts/).

# Developing/testing

If you want to test this out yourself, you can.  I run it on Kubernetes in Docker for Mac, but the instructions should basically be the same:
```
git clone https://github.com/jacobsalmela/sampo.git
cd sampo/
kubectl create -f sampo/
```

## Testing changes
I use a simple build script to delete my current deployment, re-deploy it, and set up port forwarding (this all assumes local development on Docker for Mac).  Then I just run:
```
./build.sh
```
I currently use [`bats-core`](https://github.com/bats-core/bats-core) in the script.  It doesn't work all that well, but it's a nice indicator if something is immediately wrong.
