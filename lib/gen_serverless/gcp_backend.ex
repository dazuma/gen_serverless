defmodule GenServerless.GcpBackend do
  alias GenServerless.Backend
  alias GoogleApi.Datastore.V1.Model, as: DatastoreModel
  alias GoogleApi.Datastore.V1.Api.Projects, as: DatastoreService
  alias GoogleApi.PubSub.V1.Model, as: PubSubModel
  alias GoogleApi.PubSub.V1.Api.Projects, as: PubSubService
  alias GenServerless.GcpBackend.TransactionInfo
  alias GenServerless.GcpBackend.Impl

  @behaviour Backend

  @kind "Process"
  @min_retry_delay 50
  @max_retry_delay 400

  defmodule ServerState do
    defstruct(
      module: nil,
      state: nil,
      deadline: 0
    )
  end

  defmodule ServerEvent do
    defstruct(
      id: nil,
      type: nil,
      data: nil
    )
  end

  defmodule TransactionInfo do
    defstruct(
      project: nil,
      connection: nil,
      key: nil,
      name: nil,
      transaction: nil,
      retries: 10
    )
  end

  require Logger

  def start_link(init_arg) do
    Impl.start_link(init_arg)
  end

  def child_spec(init_arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [init_arg]}
    }
  end

  @impl Backend
  def start_server(name, module, init_arg) do
    Logger.debug(
      "[GcpBackend] start_server: name=#{inspect(name)} module=#{inspect(module)} init_arg=#{
        inspect(init_arg)
      }"
    )

    in_transaction(name, fn xact ->
      server = %ServerState{module: module}
      event = %ServerEvent{type: :init, data: init_arg}
      server_entity = server_to_entity(xact, server)
      event_entity = event_to_entity(xact, event)
      server_mutation = %DatastoreModel.Mutation{insert: server_entity}
      event_mutation = %DatastoreModel.Mutation{insert: event_entity}
      {:ok, :ok, [server_mutation, event_mutation]}
    end)
    |> case do
      {:ok, :ok} ->
        Logger.debug("  [GcpBackend] start_server: Started")
        :ok

      {:error, error} ->
        Logger.warn("  [GcpBackend] start_server: Error: #{inspect(error)}")
        {:error, error}
    end
  end

  @impl Backend
  def stop_server(name, reason) do
    Logger.debug("[GcpBackend] stop_server: name=#{inspect(name)}, reason=#{inspect(reason)}")

    in_transaction(name, fn xact ->
      case fetch_server_queue_keys(xact) do
        {:ok, keys} ->
          event_removals = Enum.map(keys, &%DatastoreModel.Mutation{delete: &1})
          {:ok, :ok, [%DatastoreModel.Mutation{delete: xact.key} | event_removals]}

        {:error, _} = error ->
          error
      end
    end)
    |> case do
      {:ok, :ok} ->
        Logger.debug("  [GcpBackend] stop_server: Stopped")
        :ok

      {:error, error} ->
        Logger.warn("  [GcpBackend] stop_server: Error: #{inspect(error)}")
        {:error, error}
    end
  end

  @impl Backend
  def acquire_state(name, timeout) do
    Logger.debug("[GcpBackend] acquire_state: name=#{inspect(name)}")
    cur_time = System.system_time(:millisecond)

    in_transaction(name, fn xact ->
      case fetch_server_info(xact) do
        {:ok, %ServerState{deadline: 0}, nil} ->
          Logger.debug("  [GcpBackend] acquire_state: Try empty")
          {:ok, :empty, []}

        {:ok, %ServerState{deadline: 0} = server, event} ->
          event_reply(xact, server, event, nil, cur_time + timeout)

        {:ok, %ServerState{}, _event} ->
          Logger.debug("  [GcpBackend] acquire_state: Try busy")
          {:ok, :busy, []}

        {:error, _} = error ->
          error
      end
    end)
    |> case do
      {:ok, {type, data, module, state, backend_info}} ->
        Logger.debug(
          "  [GcpBackend] acquire_state: Returning type=#{inspect(type)} data=#{inspect(data)} state=#{
            inspect(state)
          }"
        )

        {:ok, type, data, module, state, backend_info}

      {:ok, :empty} ->
        Logger.debug("  [GcpBackend] acquire_state: Returning empty")
        {:ok, :busy}

      {:ok, :busy} ->
        Logger.debug("  [GcpBackend] acquire_state: Returning busy")
        {:ok, :busy}

      {:error, error} ->
        Logger.warn("  [GcpBackend] acquire_state: Error: #{inspect(error)}")
        {:error, error}
    end
  end

  @impl Backend
  def acquire_state(name, ntype, ndata, timeout) do
    Logger.debug(
      "[GcpBackend] acquire_state: name=#{inspect(name)} type=#{inspect(ntype)} data=#{
        inspect(ndata)
      }"
    )

    cur_time = System.system_time(:millisecond)
    nevent = %ServerEvent{type: ntype, data: ndata}

    in_transaction(name, fn xact ->
      case fetch_server_info(xact) do
        {:ok, %ServerState{deadline: 0} = server, nil} ->
          event_reply(xact, server, nevent, nil, cur_time + timeout)

        {:ok, %ServerState{deadline: 0} = server, event} ->
          event_reply(xact, server, event, nevent, cur_time + timeout)

        {:ok, %ServerState{}, _event} ->
          Logger.debug("  [GcpBackend] acquire_state: Try queued")
          nevent_entity = event_to_entity(xact, nevent)
          nevent_mutation = %DatastoreModel.Mutation{insert: nevent_entity}
          {:ok, :busy, [nevent_mutation]}

        {:error, _} = error ->
          error
      end
    end)
    |> case do
      {:ok, {type, data, module, state, backend_info}} ->
        Logger.debug(
          "  [GcpBackend] acquire_state: Returning type=#{inspect(type)} data=#{inspect(data)} state=#{
            inspect(state)
          }"
        )

        {:ok, type, data, module, state, backend_info}

      {:ok, :busy} ->
        Logger.debug("  [GcpBackend] acquire_state: Returning queued")
        {:ok, :busy}

      {:error, error} ->
        Logger.warn("  [GcpBackend] acquire_state: Error: #{inspect(error)}")
        {:error, error}
    end
  end

  @impl Backend
  def release_state(name, state, {event_id}) do
    Logger.debug("[GcpBackend] release_state: name=#{inspect(name)} state=#{inspect(state)}")

    in_transaction(name, fn xact ->
      case fetch_server_state(xact) do
        {:ok, %ServerState{} = server} ->
          case fetch_server_queue_keys(xact) do
            {:ok, keys} ->
              event_avail =
                Enum.any?(keys, fn key ->
                  [_, %DatastoreModel.PathElement{id: id}] = key.path
                  String.to_integer(id) != event_id
                end)

              if server.deadline == 0 do
                Logger.warn("  [GcpBackend] release_state: Unexpectedly not handling event")
              else
                Logger.debug(
                  "  [GcpBackend] release_state: Try returning state with event_avail=#{
                    event_avail
                  }"
                )
              end

              server = %ServerState{server | deadline: 0, state: state}
              server_entity = server_to_entity(xact, server)
              server_mutation = %DatastoreModel.Mutation{update: server_entity}

              mutations =
                if event_id == nil do
                  [server_mutation]
                else
                  key = make_event_key(xact, event_id)
                  event_mutation = %DatastoreModel.Mutation{delete: key}
                  [server_mutation, event_mutation]
                end

              {:ok, event_avail, mutations}

            {:error, _} = error ->
              error
          end

        {:error, _} = error ->
          error
      end
    end)
    |> case do
      {:ok, event_avail} ->
        Logger.debug("  [GcpBackend] release_state: State released, event_avail=#{event_avail}")
        {:ok, event_avail}

      {:error, error} ->
        Logger.warn("  [GcpBackend] release_state: Error: #{inspect(error)}")
        {:error, error}
    end
  end

  @impl Backend
  def post_cast(name, msg) do
    Logger.debug("[GcpBackend] post_cast: name=#{inspect(name)} msg=#{inspect(msg)}")
    attrs = Backend.make_cast_attrs(name)
    encoded_data = msg |> Backend.encode_term() |> Base.encode64()
    post(%PubSubModel.PubsubMessage{attributes: attrs, data: encoded_data})
  end

  @impl Backend
  def post_stop(name, reason) do
    Logger.debug("[GcpBackend] post_stop: name=#{inspect(name)} reason=#{inspect(reason)}")
    attrs = Backend.make_stop_attrs(name)
    encoded_data = reason |> Backend.encode_term() |> Base.encode64()
    post(%PubSubModel.PubsubMessage{attributes: attrs, data: encoded_data})
  end

  @impl Backend
  def post_ready(name) do
    Logger.debug("[GcpBackend] post_ready: name=#{inspect(name)}")
    attrs = Backend.make_ready_attrs(name)
    post(%PubSubModel.PubsubMessage{attributes: attrs})
  end

  defp post(message) do
    request = %PubSubModel.PublishRequest{messages: [message]}
    project = System.fetch_env!("GOOGLE_CLOUD_PROJECT")
    topic = Application.fetch_env!(:gen_serverless, :pubsub_topic)
    conn = GoogleApi.PubSub.V1.Connection.new(&get_token/1)
    PubSubService.pubsub_projects_topics_publish(conn, project, topic, body: request)
    :ok
  end

  defp event_reply(xact, server, ret_event, queue_event, deadline) do
    Logger.debug(
      "  [GcpBackend] acquire_event: Try returning type=#{inspect(ret_event.type)} data=#{
        inspect(ret_event.data)
      } state=#{inspect(server.state)}"
    )

    server = %ServerState{server | deadline: deadline}
    server_entity = server_to_entity(xact, server)
    server_mutation = %DatastoreModel.Mutation{update: server_entity}

    mutations =
      if queue_event == nil do
        [server_mutation]
      else
        event_entity = event_to_entity(xact, queue_event)
        event_mutation = %DatastoreModel.Mutation{insert: event_entity}
        [server_mutation, event_mutation]
      end

    {:ok, {ret_event.type, ret_event.data, server.module, server.state, {ret_event.id}},
     mutations}
  end

  defp fetch_server_state(xact) do
    Logger.debug("  [GcpBackend] Querying server state")

    request = %DatastoreModel.LookupRequest{
      keys: [xact.key],
      readOptions: %DatastoreModel.ReadOptions{transaction: xact.transaction}
    }

    case DatastoreService.datastore_projects_lookup(xact.connection, xact.project, body: request) do
      {:ok, %DatastoreModel.LookupResponse{found: [%DatastoreModel.EntityResult{entity: entity}]}} ->
        {:ok, entity_to_server(entity)}

      {:ok, %DatastoreModel.LookupResponse{missing: [_result]}} ->
        {:error, :notfound}

      {:ok, response} ->
        {:error, {:unknown_response, response}}

      {:error, _} = error_response ->
        error_response
    end
  end

  defp fetch_server_info(xact) do
    Logger.debug("  [GcpBackend] Querying full server info")

    request = %DatastoreModel.RunQueryRequest{
      partitionId: xact.key.partitionId,
      query: %DatastoreModel.Query{
        distinctOn: %DatastoreModel.PropertyReference{name: "class"},
        filter: %DatastoreModel.Filter{
          propertyFilter: %DatastoreModel.PropertyFilter{
            op: "HAS_ANCESTOR",
            property: %DatastoreModel.PropertyReference{name: "__key__"},
            value: %DatastoreModel.Value{keyValue: xact.key}
          }
        },
        kind: %DatastoreModel.KindExpression{name: @kind}
      },
      readOptions: %DatastoreModel.ReadOptions{transaction: xact.transaction}
    }

    case DatastoreService.datastore_projects_run_query(xact.connection, xact.project,
           body: request
         ) do
      {:ok,
       %DatastoreModel.RunQueryResponse{
         batch: %DatastoreModel.QueryResultBatch{entityResults: nil}
       }} ->
        {:error, :notfound}

      {:ok,
       %DatastoreModel.RunQueryResponse{
         batch: %DatastoreModel.QueryResultBatch{entityResults: results}
       }} ->
        {server, event} =
          results
          |> Enum.map(& &1.entity)
          |> interpret_entities(nil, nil)

        {:ok, server, event}

      {:ok, response} ->
        {:error, {:unknown_response, response}}

      {:error, _} = error_response ->
        error_response
    end
  end

  defp fetch_server_queue_keys(xact) do
    Logger.debug("  [GcpBackend] Querying server queue keys")

    request = %DatastoreModel.RunQueryRequest{
      partitionId: xact.key.partitionId,
      query: %DatastoreModel.Query{
        filter: %DatastoreModel.Filter{
          propertyFilter: %DatastoreModel.PropertyFilter{
            op: "HAS_ANCESTOR",
            property: %DatastoreModel.PropertyReference{name: "__key__"},
            value: %DatastoreModel.Value{keyValue: xact.key}
          }
        },
        kind: %DatastoreModel.KindExpression{name: @kind},
        projection: %DatastoreModel.Projection{
          property: %DatastoreModel.PropertyReference{name: "__key__"}
        }
      },
      readOptions: %DatastoreModel.ReadOptions{transaction: xact.transaction}
    }

    case DatastoreService.datastore_projects_run_query(xact.connection, xact.project,
           body: request
         ) do
      {:ok,
       %DatastoreModel.RunQueryResponse{
         batch: %DatastoreModel.QueryResultBatch{entityResults: nil}
       }} ->
        {:error, :notfound}

      {:ok,
       %DatastoreModel.RunQueryResponse{
         batch: %DatastoreModel.QueryResultBatch{entityResults: results}
       }} ->
        keys =
          Enum.flat_map(results, fn result ->
            key = result.entity.key

            case key.path do
              [_, %DatastoreModel.PathElement{id: id}] when is_binary(id) ->
                [key]

              _ ->
                []
            end
          end)

        {:ok, keys}

      {:ok, response} ->
        {:error, {:unknown_response, response}}

      {:error, _} = error_response ->
        error_response
    end
  end

  defp interpret_entities([], server, event), do: {server, event}

  defp interpret_entities(
         [
           %DatastoreModel.Entity{
             properties: %{"class" => %DatastoreModel.Value{stringValue: "state"}}
           } = entity
           | entities
         ],
         _,
         event
       ) do
    interpret_entities(entities, entity_to_server(entity), event)
  end

  defp interpret_entities(
         [
           %DatastoreModel.Entity{
             properties: %{"class" => %DatastoreModel.Value{stringValue: "init"}}
           } = entity
           | entities
         ],
         server,
         _
       ) do
    interpret_entities(entities, server, entity_to_event(entity))
  end

  defp interpret_entities(
         [
           %DatastoreModel.Entity{
             properties: %{"class" => %DatastoreModel.Value{stringValue: "event"}}
           } = entity
           | entities
         ],
         server,
         nil
       ) do
    interpret_entities(entities, server, entity_to_event(entity))
  end

  defp interpret_entities(
         [
           %DatastoreModel.Entity{
             properties: %{"class" => %DatastoreModel.Value{stringValue: "event"}}
           }
           | entities
         ],
         server,
         event
       ) do
    interpret_entities(entities, server, event)
  end

  defp make_event_key(xact, id) do
    %DatastoreModel.Key{
      partitionId: %DatastoreModel.PartitionId{namespaceId: "", projectId: xact.project},
      path: [
        %DatastoreModel.PathElement{kind: @kind, name: xact.name},
        %DatastoreModel.PathElement{kind: @kind, id: id}
      ]
    }
  end

  defp in_transaction(name, func) do
    project = System.fetch_env!("GOOGLE_CLOUD_PROJECT")
    conn = GoogleApi.Datastore.V1.Connection.new(&get_token/1)
    partition = %DatastoreModel.PartitionId{namespaceId: "", projectId: project}
    path_element = %DatastoreModel.PathElement{kind: @kind, name: name}
    key = %DatastoreModel.Key{partitionId: partition, path: [path_element]}
    xact = %TransactionInfo{project: project, connection: conn, key: key, name: name}
    transaction_loop(xact, func, {:error, :noretries})
  end

  defp transaction_loop(
         %TransactionInfo{retries: retries, transaction: prev_transaction} = xact,
         func,
         _
       )
       when retries > 0 do
    Logger.debug(
      "  [GcpBackend] Starting transaction attempt: retries=#{inspect(retries)} prev=#{
        inspect(prev_transaction)
      }"
    )

    read_write = %DatastoreModel.ReadWrite{previousTransaction: prev_transaction}
    transaction_options = %DatastoreModel.TransactionOptions{readWrite: read_write}
    request = %DatastoreModel.BeginTransactionRequest{transactionOptions: transaction_options}

    case DatastoreService.datastore_projects_begin_transaction(xact.connection, xact.project,
           body: request
         ) do
      {:ok, %DatastoreModel.BeginTransactionResponse{transaction: transaction}} ->
        Logger.debug("  [GcpBackend] Got a transaction: #{inspect(transaction)}")
        xact = %TransactionInfo{xact | transaction: transaction, retries: retries - 1}

        case func.(xact) do
          {:ok, response, []} ->
            Logger.debug("  [GcpBackend] No mutations to commit: #{inspect(response)}")
            transaction_rollback(xact)
            {:ok, response}

          {:ok, response, mutations} ->
            request = %DatastoreModel.CommitRequest{
              mutations: mutations,
              transaction: transaction
            }

            Logger.debug(
              "  [GcpBackend] Committing mutations: transaction=#{inspect(transaction)} mutations=#{
                inspect(mutations)
              }"
            )

            case DatastoreService.datastore_projects_commit(xact.connection, xact.project,
                   body: request
                 ) do
              {:ok, _} ->
                Logger.debug("  [GcpBackend] Commit ok: #{inspect(response)}")
                {:ok, response}

              {:error, %Tesla.Env{body: error_message}} = error ->
                case Jason.decode(error_message) do
                  {:ok, %{"error" => %{"status" => "ABORTED"}}} ->
                    Logger.debug("  [GcpBackend] Retrying transaction: #{inspect(transaction)}")
                    rand_delay()
                    transaction_loop(xact, func, error)

                  _ ->
                    Logger.warn("  [GcpBackend] Commit failed: #{inspect(error)}")
                    transaction_rollback(xact)
                    error
                end

              {:error, _} = error ->
                Logger.warn("  [GcpBackend] Commit failed: #{inspect(error)}")
                transaction_rollback(xact)
                error
            end

          {:error, _} = error ->
            transaction_rollback(xact)
            error
        end

      {:ok, response} ->
        {:error, {:unknown_response, response}}

      {:error, _} = error_response ->
        Logger.warn("  [GcpBackend] Failed to get a transaction")
        error_response
    end
  end

  defp transaction_loop(%TransactionInfo{transaction: nil}, _, error) do
    Logger.warn("  [GcpBackend] Transaction retries ran out")
    error
  end

  defp transaction_loop(xact, _, error) do
    Logger.warn("  [GcpBackend] Transaction retries ran out")
    transaction_rollback(xact)
    error
  end

  defp transaction_rollback(xact) do
    Logger.debug("  [GcpBackend] Rolling back transaction")
    request = %DatastoreModel.RollbackRequest{transaction: xact.transaction}
    DatastoreService.datastore_projects_rollback(xact.connection, xact.project, body: request)
  end

  defp entity_to_server(%DatastoreModel.Entity{
         properties: %{
           "module" => %DatastoreModel.Value{stringValue: module},
           "data" => %DatastoreModel.Value{stringValue: state},
           "deadline" => %DatastoreModel.Value{integerValue: deadline}
         }
       }) do
    %ServerState{
      module: String.to_existing_atom(module),
      state: Backend.decode_term(state),
      deadline: String.to_integer(deadline)
    }
  end

  defp entity_to_event(%DatastoreModel.Entity{
         key: %DatastoreModel.Key{
           path: [_, %DatastoreModel.PathElement{id: id}]
         },
         properties: %{
           "type" => %DatastoreModel.Value{stringValue: type},
           "data" => %DatastoreModel.Value{stringValue: data}
         }
       }) do
    %ServerEvent{
      id: String.to_integer(id),
      type: String.to_existing_atom(type),
      data: Backend.decode_term(data)
    }
  end

  defp server_to_entity(xact, server) do
    class = %DatastoreModel.Value{stringValue: "state"}

    module = %DatastoreModel.Value{
      stringValue: Atom.to_string(server.module),
      excludeFromIndexes: true
    }

    state = %DatastoreModel.Value{
      stringValue: Backend.encode_term(server.state),
      excludeFromIndexes: true
    }

    deadline = %DatastoreModel.Value{
      integerValue: Integer.to_string(server.deadline),
      excludeFromIndexes: true
    }

    %DatastoreModel.Entity{
      key: xact.key,
      properties: %{"class" => class, "module" => module, "data" => state, "deadline" => deadline}
    }
  end

  defp event_to_entity(xact, event) do
    class = if event.type == :init, do: "init", else: "event"
    class = %DatastoreModel.Value{stringValue: class}

    type = %DatastoreModel.Value{
      stringValue: Atom.to_string(event.type),
      excludeFromIndexes: true
    }

    data = %DatastoreModel.Value{
      stringValue: Backend.encode_term(event.data),
      excludeFromIndexes: true
    }

    %DatastoreModel.Entity{
      key: make_event_key(xact, nil),
      properties: %{"class" => class, "type" => type, "data" => data}
    }
  end

  defp get_token(scopes) do
    {:ok, token} =
      scopes
      |> Enum.join(" ")
      |> Goth.Token.for_scope(nil)

    token.token
  end

  defp rand_delay() do
    millis = @min_retry_delay + :rand.uniform(@max_retry_delay - @min_retry_delay + 1) - 1
    Process.sleep(millis)
  end

  defmodule Impl do
    def start_link(init_arg) do
      GenServer.start(__MODULE__, init_arg, name: __MODULE__)
    end

    use GenServer

    def init(arg) do
      Logger.debug("[GcpBackend] init: arg=#{inspect(arg)}")
      {:ok, %{}}
    end
  end
end
