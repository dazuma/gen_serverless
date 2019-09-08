# GenServerless

GenServerless is an experiment in merging the ideas of long-running Elixir/BEAM processes with the serverless/cloud native paradigm. It attempts to implement a GenServer-like process atop cloud services. The idea is for all callbacks to run as serverless "functions", and the process state to be persisted in a database.

## Status

This is currently a basic proof-of-concept, with a few features working, but many features still missing, and a few large caveats. Specifically:

### Features implemented

*   A plug that lets you add the worker to any web app.
*   Init and terminate callbacks.
*   State persistence
*   Cast with messages
*   Two backend implementations:
    *   A local backend that uses no cloud services. (A single local GenServer is used as the "database".)
    *   A "GCP" backend that uses Google PubSub and Google Datastore. (But see bugs.)

### Features not yet implemented

*   Call with replies
*   Timeouts
*   Continue callback
*   Code change

### Bugs

*   The GCP backend currently uses Google Datastore as the database. This is almost certainly _not_ an appropriate database for this application because of limitations on the write rate for a single document. And indeed, it tends to lock up under high load. I think Redis would be more of an ideal database candidate, but Google's managed Redis isn't supported by Cloud Run yet.
*   If a callback totally fails and doesn't return the state, the system could go into a hanged state. There needs to be some kind of timeout mechanism to allow the system to continue.

### Open issues

*   It's not clear to me how to route replies back to a caller. One option might be to set up a pubsub topic for each call, but that seems pretty heavyweight.
*   It's also not clear to me how (or even whether) this fits into supervision.

## Running the demo

A demo app is provided in the "demo" directory. It includes a simple "GenServerless" that implements a simple accumulator: you cast integers at it, and it will add them together. This code is in `demo/lib/demo/server.ex`.

### Prerequisites

You'll need to install:

*   Elixir 1.9 or later, with hex and rebar installed.
*   git (or some other way to get a clone of this directory)

If you want to run in the cloud, you'll also need:

*   A Google account
*   The gcloud SDK installed.
*   Ruby 2.3 or later, and the Toys gem (for some of the scripts)

### Running locally

To run the demo locally:

    cd demo
    mix deps.get
    mix compile
    iex -S mix phx.server

Now you can use the GenServerless API to create servers. Try:

    {:ok, s} = GenServerless.start(Demo.Server, 100)
    GenServerless.cast(s, 10)
    GenServerless.cast(s, 20)
    GenServerless.stop(s)

### Running in prod

Actually running in the cloud requires some setup. The demo provides Toys scripts to automate some of this. You can see what these scripts are actually doing by examining the `demo/.tosy.rb` file.

1.  Create a Google Cloud project, and enable billing.
2.  Enable Cloud Build, Cloud Run, Pubsub, and Firestore in Datastore mode. You can do this in the console.
3.  Set the gcloud default project to your ew project. `gcloud config set project $PROJECT_ID`.
4.  cd into the `demo` directory.
5.  Build base images by running `toys build-base`. Generally, this is a one-time step that won't need to be repeated unless your dependencies change. This will build some base images that include Elixir and the app dependencies but not the demo app itself.
6.  Build and deploy the demo app to Cloud Run by running `toys deploy`. This builds the app image and pushes it to Cloud Run. If you change the app, repeat this step to redeploy.
7.  Complete the setup by running `toys finish-setup`. This is a one-time step that sets up the remaining needed cloud resources. It has to be run after your initial deployment to Cloud Run because it needs to know the URL for your Cloud Run service. You do not need to rerun it when redeploying. If you're curious, this script does the following:
    *   It creates a service account that will be used to access the cloud from your local console. This will allow you to interact with GenServerless processes from your local IEX prompt. It downloads a key for this account and saves it as `demo/config/service-account.json`.
    *   It creates a datastore index needed by the system.
    *   It creates a pubsub topic and subscription that will be used as the message queue for GenServerless processes.
    *   It creates another pubsub topic and subscription that will be used as a simple cloud "logger", letting you stream updates that are sent by processes running in the cloud.

Now you can test the demo:

1.  cd into the "demo" directory.
2.  In a terminal, start a process that streams logs by running `toys stream-logs`. This will let you see what's happening in the cloud.
3.  In another terminal, open a console by running `toys console --prod`. This is basically an IEX prompt with the demo application.

Now you can use the GenServerless API to create servers. Try:

    {:ok, s} = GenServerless.start(Demo.Server, 100)
    GenServerless.cast(s, 10)
    GenServerless.cast(s, 20)
    GenServerless.stop(s)
