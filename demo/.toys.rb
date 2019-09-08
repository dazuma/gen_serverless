require "psych"

mixin "demo-common" do
  on_include do
    include :exec, exit_on_nonzero_status: true
    include :terminal
    flag :project_id, "--project=VALUE", "-p VALUE"
  end

  def project
    @project ||= get(:project_id) || capture(["gcloud", "config", "get-value", "project"]).strip
  end

  def setup_runtime_env(is_prod: false, port: "4000")
    ENV["GOOGLE_APPLICATION_CREDENTIALS"] = "#{__dir__}/config/service-account.json"
    if is_prod
      ENV["MIX_ENV"] = "prod"
      ENV["GOOGLE_CLOUD_PROJECT"] = project
      ENV["PORT"] = port
    end
  end

  def base_dir
    File.dirname(context_directory)
  end
end

tool "build-base" do
  desc "Prebuild dependencies for genserverless-demo"

  include "demo-common"

  flag :yes, "--yes", "-y"

  def run
    exit(1) unless yes || confirm("Prebuild demo dependencies in #{project}? ", default: true)

    puts("Building base images...", :bold, :cyan)
    exec(["gcloud", "builds", "submit",
          "--project", project,
          "--config", "demo/build/build-base.yml",
          "."],
          chdir: base_dir)
    puts("Done", :bold, :cyan)
  end
end

tool "deploy" do
  desc "Deploy genserverless-demo"

  include "demo-common"

  flag :yes, "--yes", "-y"
  flag :tag, "--tag=VALUE", "-t VALUE", default: ::Time.now.strftime("%Y-%m-%d-%H%M%S")
  flag :name, "--name=VALUE", "-n VALUE", default: "genserverless-demo"

  def run
    exit(1) unless yes || confirm("Deploy build #{tag} in project #{project}? ", default: true)

    image = "gcr.io/#{project}/#{name}:#{tag}"
    puts("Building image: #{image} ...", :bold, :cyan)
    exec(["gcloud", "builds", "submit",
          "--project", project,
          "--config", "demo/build/build-demo.yml",
          "--substitutions", "_BUILD_ID=#{tag}",
          "."],
          chdir: base_dir)
    puts("Updating deployment...", :bold, :cyan)
    exec(["gcloud", "beta", "run", "deploy", name,
          "--project", project,
          "--platform", "managed",
          "--region", "us-east1",
          "--image", image,
          "--allow-unauthenticated",
          "--concurrency", "80"])
    puts("Done", :bold, :cyan)
  end
end

tool "finish-setup" do
  desc "One-time setup of cloud resources. Run after the initial deploy but before using."

  include "demo-common"

  flag :yes, "--yes", "-y"
  flag :name, "--name=VALUE", "-n VALUE", default: "genserverless-demo"

  def run
    exit(1) unless yes || confirm("Perform one-time setup of GenServerless in project #{project}? ", default: true)

    puts("Getting deployment info...", :bold, :cyan)
    service_info = capture(["gcloud", "beta", "run", "services", "describe", "--platform=managed", "--region=us-east1", name])
    run_url = ::Psych.load(service_info)["status"]["url"]
    unless run_url
      puts("Couldn't get URL for Cloud Run service", :bold, :red)
      exit(1)
    end

    puts("Creating service account...", :bold, :cyan)
    service_account = "genserverless-local@#{project}.iam.gserviceaccount.com"
    exec(["gcloud", "iam", "service-accounts", "create", "genserverless-local",
          "--display-name", "Local access to GenServerless"])
    exec(["gcloud", "projects", "add-iam-policy-binding", project, "--member=serviceAccount:#{service_account}", "--role=roles/editor"])
    exec(["gcloud", "projects", "add-iam-policy-binding", project, "--member=serviceAccount:#{service_account}", "--role=roles/datastore.owner"])
    exec(["gcloud", "iam", "service-accounts", "keys", "create", "demo/config/service-account.json", "--iam-account=#{service_account}"],
         chdir: base_dir)
    puts("Setting up processes pubsub topic...", :bold, :cyan)
    exec(["gcloud", "pubsub", "topics", "create", "processes"])
    exec(["gcloud", "pubsub", "subscriptions", "create", "--topic=processes", "--push-endpoint", "#{run_url}/genserverless", "genserverless"])
    puts("Setting up processlogs pubsub topic...", :bold, :cyan)
    exec(["gcloud", "pubsub", "topics", "create", "processlogs"])
    exec(["gcloud", "pubsub", "subscriptions", "create", "--topic=processlogs", "logstreamer"])
    puts("Setting up datastore indexes...", :bold, :cyan)
    exec(["gcloud", "datastore", "indexes", "create", "demo/config/index.yaml"],
         chdir: base_dir)
    puts("Done", :bold, :cyan)
  end
end

tool "console" do
  include "demo-common"

  flag :prod
  flag :port, default: "8080"

  def run
    setup_runtime_env is_prod: prod, port: port
    if prod
      ::Kernel.exec("iex", "-S", "mix")
    else
      ::Kernel.exec("iex", "-S", "mix", "phx.server")
    end
  end
end

tool "stream-logs" do
  include "demo-common"

  flag :subscription, default: "logstreamer"

  def run
    setup_runtime_env is_prod: true
    ::Kernel.exec("mix", "run", "--no-start", "--no-halt", "-e",
                  "Demo.LogStreamer.run(project: #{project.inspect}, subscription: #{subscription.inspect})")
  end
end
