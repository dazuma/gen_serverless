defmodule Demo.LogWriter do
  alias GoogleApi.PubSub.V1.Model, as: PubSubModel
  alias GoogleApi.PubSub.V1.Api.Projects, as: PubSubService

  require Logger

  def log(str) when is_binary(str) do
    log([str])
  end

  def log([]), do: nil

  def log(str_list) when is_list(str_list) do
    project = System.get_env("GOOGLE_CLOUD_PROJECT")
    topic = Application.get_env(:demo, :pubsublog_topic, nil)
    if project == nil || topic == nil do
      Enum.each(str_list, &Logger.info/1)
    else
      conn = GoogleApi.PubSub.V1.Connection.new(&get_token/1)
      messages = Enum.map(str_list, fn str -> %PubSubModel.PubsubMessage{data: Base.encode64(str)} end)
      request = %PubSubModel.PublishRequest{messages: messages}
      PubSubService.pubsub_projects_topics_publish(conn, project, topic, body: request)
    end
    nil
  end

  defp get_token(scopes) do
    {:ok, token} =
      scopes
      |> Enum.join(" ")
      |> Goth.Token.for_scope(nil)
    token.token
  end
end
