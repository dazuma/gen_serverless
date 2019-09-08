defmodule Demo.LogStreamer do
  alias GoogleApi.PubSub.V1.Model, as: PubSubModel
  alias GoogleApi.PubSub.V1.Api.Projects, as: PubSubService

  require Logger

  def run(args) do
    Application.ensure_all_started(:goth)
    start_link(args)
    IO.puts("**** Streaming logs ****")
  end

  def start_link(args) do
    GenServer.start(__MODULE__, args, name: __MODULE__)
  end

  use GenServer

  def init(args) do
    project = Keyword.get(args, :project, System.fetch_env!("GOOGLE_CLOUD_PROJECT"))
    subscription = Keyword.fetch!(args, :subscription)
    conn = GoogleApi.PubSub.V1.Connection.new(&get_token/1)
    {:ok, %{project: project, connection: conn, subscription: subscription}, {:continue, :poll}}
  end

  def handle_continue(
        :poll,
        %{project: project, connection: conn, subscription: subscription} = state
      ) do
    request = %PubSubModel.PullRequest{returnImmediately: false, maxMessages: 10}

    {:ok, response} =
      PubSubService.pubsub_projects_subscriptions_pull(conn, project, subscription, body: request)

    messages = response.receivedMessages

    if messages != nil && messages != [] do
      ack_request = %PubSubModel.AcknowledgeRequest{ackIds: Enum.map(messages, & &1.ackId)}

      PubSubService.pubsub_projects_subscriptions_acknowledge(conn, project, subscription,
        body: ack_request
      )

      Enum.each(messages, fn m ->
        m.message.data
        |> Base.decode64!()
        |> IO.puts()
      end)
    end

    {:noreply, state, {:continue, :poll}}
  end

  def handle_continue(_, state), do: {:noreply, state}

  defp get_token(scopes) do
    {:ok, token} =
      scopes
      |> Enum.join(" ")
      |> Goth.Token.for_scope(nil)

    token.token
  end
end
