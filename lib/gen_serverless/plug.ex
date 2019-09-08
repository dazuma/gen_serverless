defmodule GenServerless.Plug do
  use Plug.Builder

  alias GenServerless.Backend

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:handle)

  def handle(conn, _opts) do
    Backend.handle_params(conn.body_params)
    send_resp(conn, 200, "GenServerless handled\n")
  end
end
