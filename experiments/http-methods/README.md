# Adding POST, PUT and DELETE to sampo

Before this work, sampo only answered `GET`. Any other method got a `501`, and request bodies were never read. This directory tries three ways of adding `POST`, `PUT` and `DELETE`. It tests each one with the same small pub/sub app, which streams messages to a terminal, and then recommends one.

**Option B, method-aware routes, was chosen and is now in `docker/sampo`.** `match_uri` takes an optional method before the regex (`match_uri POST '^/topics/(.+)$' topic_publish`), and a route without one only answers `GET`, as every route did before. See [why B](#why-b).

Each option is `docker/sampo` as it was at commit `294d3b7`, before option B went into it, plus patches. `lab.sh` puts each option together, so the comparison still runs. `docker/sampo/sampo.sh` is now exactly the file `lab.sh` builds for option B.

## Try it

You need `socat` (as for `./build.sh -l`) and bash 4.4 or newer as `bash` on your `PATH`. sampo needed bash 4.4 even before these changes ([finding 6](#other-things-i-found)); on a Mac that means `brew install bash`. Docker works as well.

```bash
cd experiments/http-methods
./lab.sh demo b      # serve option b, then stream a topic to this terminal while publishing to it
./lab.sh serve b     # or serve it on port 1042 and use curl from a few terminals:
```

Replace `b` with `current` to run the pub/sub app on `docker/sampo` as it is now.

```bash
curl -X PUT -d 'Daily headlines' localhost:1042/topics/news   # create a topic
curl -N localhost:1042/topics/news                              # subscribe: messages stream in as they are published
curl -X POST -d 'hello' localhost:1042/topics/news              # publish (from another terminal)
curl localhost:1042/topics                                      # list topics and their subscriber counts
curl -X DELETE localhost:1042/topics/news                       # delete the topic, which ends the stream
```

This is what `./lab.sh demo b` printed. Lines starting with `|` are what the subscriber's stream received, as it arrived:

```
== sampo (b-method-routes) on port 1042
01:12:23  PUT     /topics/news  -> created topic news (201)
== subscribing to /topics/news; the stream's lines appear as '| ...'
01:12:24  | hello from sampo
01:12:24  POST    /topics/news  -> published to 1 subscriber(s) of news (202)
01:12:25  | each POST is streamed to the subscriber right away
01:12:25  POST    /topics/news  -> published to 1 subscriber(s) of news (202)
01:12:26  | a message can have
01:12:26  POST    /topics/news  -> published to 1 subscriber(s) of news (202)
01:12:26  | more than one line
01:12:27  GET     /topics       -> news	1	Daily headlines (200)
01:12:27  DELETE  /topics/news  -> (204)
== the stream ended when the topic was deleted
```

To run it in sampo's image instead of on your machine, use `SAMPO_DOCKER_IMAGE=ghcr.io/jacobsalmela/sampo/sampo:1.0.0 ./lab.sh demo b`. I couldn't download that image where I tested, so that command is untested; the closest setup I could run is described under [results](#results). The other commands are:

- `./lab.sh test` runs the pub/sub tests against all three options, and `./lab.sh test current` runs them against `docker/sampo`.
- `./lab.sh regress` runs sampo's integration tests from commit `294d3b7` against each option. `./lab.sh regress current` runs today's tests against `docker/sampo`.
- `./lab.sh matrix` prints the status code table [below](#results).

## The pub/sub app

[`common/pubsub.sh`](common/pubsub.sh) uses each method for what HTTP means by it:

| request | does | answers |
|---|---|---|
| `PUT /topics/NAME` | creates the topic; the body is its description | 201, or 200 if it already existed |
| `POST /topics/NAME` | publishes the body to the topic's subscribers | 202 |
| `GET /topics/NAME` | subscribes: streams the topic's messages until it is deleted | 200, then a line per message |
| `GET /topics` | lists topics and how many subscribers each has | 200 |
| `DELETE /topics/NAME` | deletes the topic, which ends its subscribers' streams | 204 |

Each topic is a directory. Each subscriber is a FIFO in that directory, named after the PID of the sampo process streaming to it. `POST` writes the message into every FIFO, so subscribers get it at once, with no polling. All three options use this same file; only the wiring differs.

The handlers run inside sampo (they are sourced), not as external scripts. External scripts can't stream or choose a status code: `run_external_script` waits for all of a script's output and answers either 200 or 500. That limitation is the same whichever option you pick ([next steps](#next-steps-if-you-pick-b)).

## What every option needs

[`common/1-request-body.patch`](common/1-request-body.patch) adds 32 lines and removes 7 in `sampo.sh`, and every option builds on it:

- It parses `Content-Length` and `Content-Type`. These are the commented-out cases in `listen_for_requests`, now case-insensitive.
- It reads exactly `Content-Length` bytes into `REQUEST_BODY`, using `read -N` with `LC_ALL=C`. Without `LC_ALL=C`, bash counts characters instead of bytes. A UTF-8 body would then leave sampo waiting for bytes that never arrive; I confirmed this on bash 4.4 and 5.2.
- It checks that `Content-Length` is a number before doing arithmetic with it. Bash evaluates variables inside `(( ))`, so `Content-Length: a[$(cmd)]` would run `cmd`. A header that isn't a number gets a 400, and a body over `SAMPO_MAX_BODY` (1 MiB by default) gets a 413.
- It stops once `endpoint_exists` has sent a 404. Today a `POST` to an unknown path gets two responses, a 404 and then a 501.
- It hands the request to external scripts the way CGI does. `REQUEST_METHOD`, `CONTENT_LENGTH` and `CONTENT_TYPE` go in the environment, and the body goes to the script's STDIN. [`common/inspect.sh`](common/inspect.sh) is an example.

## The options

### A: pass-through, where each handler checks the method

[`a-passthrough/sampo.sh.patch`](a-passthrough/sampo.sh.patch) adds 2 lines and removes 1. The method check lets `POST`, `PUT` and `DELETE` through, so every route receives every method, and handlers look at `$REQUEST_METHOD` the way CGI scripts do:

```bash
topic_resource() {
  case "$REQUEST_METHOD" in
    GET)    topic_subscribe "$2" ;;
    PUT)    topic_create "$2" ;;
    POST)   topic_publish "$2" ;;
    DELETE) topic_delete "$2" ;;
    *)      append_header "Allow" "GET,PUT,POST,DELETE"; fail_with 405 ;;
  esac
}
match_uri '^/topics/(.+)$' topic_resource
```

A second handler, `topics_resource`, covers `/topics`. Together they take 19 lines of sampo.conf ([`a-passthrough/sampo.conf.patch`](a-passthrough/sampo.conf.patch)).

- **For:** it's the smallest possible change, and it follows the familiar CGI model.
- **Against:** every existing route now answers every method as if it were `GET`. `DELETE /example` runs `example.sh` and answers 200, and `POST /dir//` lists `/`. To make an existing route refuse other methods, you have to add a method check to it.
- **Against:** each handler has to write its own 405 and `Allow` header, and nothing checks that it did.
- **Against:** sampo can't tell which methods a route takes, so the `/` listing can't show them.

### B: method-aware routes in sampo.conf

[`b-method-routes/sampo.sh.patch`](b-method-routes/sampo.sh.patch) adds 28 lines and removes 4. `match_uri` accepts an optional method before the regex. A route without one only answers `GET`, so every existing line keeps its meaning. When a path only matches routes for other methods, sampo answers 405, with an `Allow` header built from those routes. When nothing matches, it answers 404.

```bash
match_uri GET    '^/topics$'      topic_list
match_uri GET    '^/topics/(.+)$' topic_subscribe
match_uri PUT    '^/topics/(.+)$' topic_create
match_uri POST   '^/topics/(.+)$' topic_publish
match_uri DELETE '^/topics/(.+)$' topic_delete
```

Wiring the app takes 7 lines of sampo.conf ([`b-method-routes/sampo.conf.patch`](b-method-routes/sampo.conf.patch)).

- **For:** existing routes stay `GET`-only. Other methods get a 405 instead of running them.
- **For:** sampo.conf is still the one place the API is defined, and now it also says which methods each route takes. The `/` listing shows them, for example `POST /topics/:topic_publish`.
- **For:** the 405, the `Allow` header and the 404 come from the routes rather than from each handler. The 404 also fixes paths like `/example/extra`, which get an empty reply today.
- **Against:** the `/` listing gains a method column, so one assertion in `test/sampo_integration.bats` needs updating. If that listing must not change at all, B could show the method only for routes that aren't `GET`.
- **Against:** a regex that is exactly `GET`, `POST`, `PUT` or `DELETE` would be read as a method. That's unlikely in practice.

### C: method-named files in routes/

[`c-method-files/sampo.sh.patch`](c-method-files/sampo.sh.patch) adds 51 lines and removes 2. A file named `routes/NAME/METHOD.sh` handles `METHOD /NAME`. A directory named `@` matches any one path segment and passes it to the handler as an argument. sampo sources the file for the request's method; if there is none, it answers 405 with an `Allow` header listing the files that do exist. Routes in sampo.conf keep working as they do today, `GET` only.

```
c-method-files/routes/
├── inspect/POST.sh
└── topics/
    ├── GET.sh           GET /topics          → topic_list
    └── @/
        ├── DELETE.sh    DELETE /topics/NAME  → topic_delete "$1"
        ├── GET.sh       GET /topics/NAME     → topic_subscribe "$1"
        ├── POST.sh      POST /topics/NAME    → topic_publish "$1"
        └── PUT.sh       PUT /topics/NAME     → topic_create "$1"
```

Wiring the app takes 11 lines across 6 files and no sampo.conf changes.

- **For:** there's nothing to configure. Adding a method means adding a file, and `ls -R routes` shows the whole API.
- **For:** the 405 and `Allow` header are automatic, and existing routes are unaffected.
- **Against:** it adds a second routing system next to sampo.conf, with different rules. Paths are matched by segment instead of by regex, arguments are positional, and users have to learn which system takes precedence. File routes also run before sampo.conf is read, so they can't use anything defined there.
- **Against:** it turns URLs into file paths, which needs more care. Every path segment has to be validated, and so does the method before it becomes part of a file name.
- **Against:** it's the biggest change to `sampo.sh`, and handlers must be bash, because they're sourced so that they can use `send_response`.

## Results

- **Pub/sub tests.** [`test/pubsub.bats`](test/pubsub.bats) has 15 tests: create and update, streaming to two subscribers, `DELETE` ending the streams, 404s after `DELETE`, UTF-8, a 200 KB message, a subscriber disconnecting, the 400, 405 and 501 cases, external scripts, existing routes, and `/`. All 15 pass for all three options in two setups:
  - on this machine, with bash 5.2.21 and socat 1.8;
  - in `bash:4.4`, the image sampo's Dockerfile builds on (bash 4.4.23 and busybox 1.37), served by busybox's `nc -lk -e` instead of socat. I couldn't build sampo's image itself because its packages couldn't be downloaded here.
- **sampo's own tests** (`./lab.sh regress`, with the stock sampo.conf). The original, A and C pass all 14. B passes 13; the one failure is the `/` listing, which now shows methods.
- **Load.** With 40 publishers posting at once and 3 subscribers, every subscriber received all 40 messages intact. This held for all three options in both setups.
- **Latency** (median of 30 requests on this machine). A `POST` takes 41 ms with A or B and 27 ms with C. Subscribers receive each message before the publisher's `202` arrives.
  - C is faster only because it answers before sampo.conf is read. sampo.conf runs `basename` and `dirname` on every request.
  - With those calls replaced by parameter expansion (`${0##*/}`), B also takes 27 ms.

These are the status codes each version answers the same requests with (`./lab.sh matrix`). `404+501` means two responses to one request, and `none` means an empty reply:

| request                    | original | a-passthrough | b-method-routes | c-method-files |
|----------------------------|----------|---------------|-----------------|----------------|
| `PUT /topics/news`         | 404+501  | 201           | 201             | 201            |
| `POST /topics/news`        | 404+501  | 202           | 202             | 202            |
| `GET /topics`              | 404      | 200           | 200             | 200            |
| `DELETE /topics/news`      | 404+501  | 204           | 204             | 204            |
| `PATCH /topics/news`       | 404+501  | 501           | 501             | 501            |
| `DELETE /topics`           | 404+501  | 405           | 405             | 405            |
| `POST /inspect`            | 404+501  | 200           | 200             | 200            |
| `GET /inspect`             | 404      | 200           | 405             | 405            |
| `GET /example`             | 200      | 200           | 200             | 200            |
| `DELETE /example`          | 501      | 200           | 405             | 501            |
| `POST /dir//`              | 501      | 200           | 405             | 501            |
| `POST /nope`               | 404+501  | 404           | 404             | 404            |
| `GET /example/extra`       | none     | none          | 404             | none           |

## Comparison

| | A: pass-through | B: method-aware routes | C: method-named files |
|---|---|---|---|
| lines changed in `sampo.sh`, on top of the shared +32 −7 | +2 −1 | +28 −4 | +51 −2 |
| wiring the pub/sub app | 19 lines in sampo.conf | 7 lines in sampo.conf | 11 lines in 6 files |
| what decides the method | each handler | sampo.conf | the `routes/` tree |
| an existing route, asked for `DELETE` | runs as if it were `GET` | 405 | 501, as today |
| 405 with `Allow` | written by hand in each handler | automatic | automatic |
| `/` shows methods | no | yes | for `routes/` only |
| paths are matched by | regex | regex | path segments and `@` |
| sampo's integration tests | 14/14 | 13/14 (the `/` listing) | 14/14 |

## Why B

1. **It adds methods without changing what existing endpoints do, and without a second routing system.**
   - A is smaller, but every endpoint then answers every method. A client that sends `DELETE /example` gets a 200 and has every reason to think something was deleted; in fact `example.sh` ran as if the request were a `GET`. Every existing endpoint would need auditing.
   - C leaves existing endpoints alone, but by putting new ones somewhere else, under different rules.
2. **It keeps sampo's model.** sampo.conf lists the endpoints and scripts/ holds the scripts. Users learn one optional word per route, and sampo.conf remains the single place to read the API from, methods included.
3. **It gets the HTTP details right by default.** The 405, the `Allow` header and the 404 come from the route table, instead of relying on every handler's author to remember them. In A, the `DELETE /topics` test passes only because I wrote that `case` by hand.
4. **It's small and easy to review.** It changes 28 lines, most of them in `match_uri`. Until users give a route a method, the only differences they see are the method column in the `/` listing, and a 405 where sampo used to send a 501.
5. **It doesn't rule out the others.** A handler wired to several methods can still check `$REQUEST_METHOD`, as in A. File routes, as in C, could later be added on top of the same `match_uri`.

## Next steps

1. **Done:** `docker/sampo/sampo.sh` now has `common/0-linux-logging.patch`, `common/1-request-body.patch` and `b-method-routes/sampo.sh.patch`, unchanged. `sampo.conf` and the README document the method argument, and `sampo.conf` has a `POST /example` rule. `test/sampo_integration.bats` covers the new behavior.
2. Let external scripts stream and choose their own status code. `run_external_script` still waits for all of a script's output and answers 200 or 500, which is why the pub/sub handlers are sourced functions. The CGI answer is to have the script print a `Status:` line and headers before its output.
3. Decide what `HEAD` and `OPTIONS` should do; both still get a 501. `HEAD` could be answered as `GET` without the body, and `OPTIONS` from the route table.

## Other things I found

These issues were already in sampo, independent of adding methods. The first three are fixed in `docker/sampo` now:

1. **On Linux hosts, every response ended with a `** FAILURE **` banner (fixed).**
   - `container_check` decides sampo runs in a container whenever `/proc/1/cgroup` exists, and that file exists on every Linux machine. So sampo logged to `/proc/1/fd/1`, which fails unless it can write to PID 1's STDOUT. The `ERR` trap then printed the banner into the response.
   - [`common/0-linux-logging.patch`](common/0-linux-logging.patch) fixes this in one line by also checking that the file is writable. `lab.sh` applies it to every build, including `original`.
2. **A request with any method other than `GET` to an unknown path got two responses**, a 404 and then a 501 (fixed by the shared patch).
3. **A path that starts like an endpoint but matches no route, such as `/example/extra`, got an empty reply** (fixed by B's 404).
4. **`send_response` strips leading whitespace from every line, and drops a last line that has no newline.** A file containing `    indented` followed by `last` without a newline is served as just `indented`. Changing the loop to `while IFS= read -r LINE || [[ -n $LINE ]]` would fix it.
5. **sampo.conf adds about 14 ms to every request**, because `$(basename ${0})` and `$(dirname …)` start new processes. Parameter expansion would make each request about a third faster.
6. **On bash 3.2, which macOS ships as `/bin/bash`, every `run_external_script` route answers 500.** The error is `args[@]: unbound variable`: with `set -u`, bash before 4.4 treats an empty array as unset. So sampo already needed bash 4.4, and these changes don't raise that requirement.

One more thing, useful to anyone writing handlers that process request bodies. When a string doesn't end with the pattern, `${var%pattern}` takes time quadratic in the string's length. It took 4.5 s on a 900 KB string, and 39 s under a UTF-8 locale. A benchmark caught this in `pubsub.sh`, which now avoids it.

## Limits of the pub/sub app

It exists to exercise the options; it isn't a message broker:

- Messages aren't stored. Each message goes to whoever is subscribed when it's published.
- sampo only notices that a subscriber disconnected when it next writes a message to it. At that point the subscriber's process exits and its FIFO is removed.
- Messages larger than a pipe's atomic write size (4 KiB) can interleave if they're published at the same moment.
- Bodies are text, because bash variables can't hold NUL bytes.

## Files

```
experiments/http-methods/
├── lab.sh                        build, serve, demo, test, regress, matrix
├── common/
│   ├── 0-linux-logging.patch     the fix for finding 1, applied to every build
│   ├── 1-request-body.patch      the change every option needs
│   ├── pubsub.sh                 the pub/sub app
│   └── inspect.sh                an external script that prints what it receives
├── a-passthrough/                sampo.sh.patch, sampo.conf.patch
├── b-method-routes/              sampo.sh.patch, sampo.conf.patch
├── c-method-files/               sampo.sh.patch, routes/
└── test/pubsub.bats
```
