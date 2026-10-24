defmodule AthenaWeb.Hooks.Trace do
  @moduledoc """
  Logs every step a LiveView takes, so one user's session can be followed
  from mount to the last event.

  Attached once from `AthenaWeb.live_view/0`, so it covers every LiveView in
  the app - including ones added later - without a line of logging inside the
  callbacks themselves. `Phoenix.LiveView.attach_hook/4` runs for
  `:handle_params`, `:handle_event`, `:handle_info` and `:handle_async`, and
  `on_mount/4` itself covers the mount, which is every callback a LiveView
  has bar `terminate/2`.

  ## Correlating lines

  Every line carries `trace=<socket id>`, and that id is the same
  `phx-...` value the client sends in its `lv:` topic - so a request captured
  in the browser's network tab can be matched to its server-side trail
  directly. `user=` carries the account's login once authentication has run.

  Because a connected LiveView is one long-lived process, the metadata is set
  once at mount and then rides along on *every* log line that process emits -
  including `Ecto` query logs and anything a context function logs. Following
  a session is `grep trace=phx-GOB1D55ZbsQJ8XJh`.

  ## Levels and volume

  Steps log at `:debug`, which is on in dev and off under the `:info` default
  in prod (set `LOG_LEVEL=debug` to turn it on there). Event *payloads* are
  passed through `Phoenix.Logger.filter_values/1`, so anything named in
  `config :phoenix, :filter_parameters` is redacted rather than printed.

  `Phoenix.LiveView.Logger` already logs mount/handle_params/handle_event
  with timings; this adds the correlation metadata, the payloads, and the two
  callbacks it does not cover. To silence the stock half and keep only this
  one, a LiveView can `use Phoenix.LiveView, log: false`.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  require Logger

  @doc """
  Sets the trace metadata and attaches a hook to every traceable callback.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(_name, params, _session, socket) do
    Logger.metadata(trace: socket.id, lv: inspect(socket.view), user: user(socket))

    log("mount", %{
      connected: connected?(socket),
      routed: routed?(params, socket),
      params: filter(params)
    })

    {:cont,
     socket
     |> maybe_attach_params(params)
     |> attach_hook(:trace_handle_event, :handle_event, &trace_event/3)
     |> attach_hook(:trace_handle_info, :handle_info, &trace_info/2)
     |> attach_hook(:trace_handle_async, :handle_async, &trace_async/3)}
  end

  # A LiveView rendered through `live_render/3` rather than a route (the
  # builder's test-run modal nests the player this way) has no
  # `handle_params/3` at all: attaching a hook for that stage is what makes
  # LiveView decide the callback exists, and it then raises on mount with
  # "not mounted nor accessed through the router live/3 macro". Such a mount
  # is handed `:not_mounted_at_router` in place of params.
  defp maybe_attach_params(socket, params) do
    if routed?(params, socket) do
      attach_hook(socket, :trace_handle_params, :handle_params, &trace_params/3)
    else
      socket
    end
  end

  defp routed?(:not_mounted_at_router, _socket), do: false
  defp routed?(_params, %{host_uri: :not_mounted_at_router}), do: false
  defp routed?(_params, %{router: nil}), do: false
  defp routed?(_params, _socket), do: true

  defp trace_params(params, uri, socket) do
    refresh_user(socket)
    log("handle_params", %{uri: path(uri), params: filter(params)})
    {:cont, socket}
  end

  defp trace_event(event, params, socket) do
    refresh_user(socket)
    log("handle_event", %{event: event, params: filter(params)})
    {:cont, socket}
  end

  defp trace_info(message, socket) do
    log("handle_info", %{message: summarize(message)})
    {:cont, socket}
  end

  defp trace_async(name, result, socket) do
    log("handle_async", %{name: inspect(name), result: async_outcome(result)})
    {:cont, socket}
  end

  defp log(step, details) do
    Logger.debug(fn ->
      ["[trace] ", step, " ", inspect(details, limit: 20, printable_limit: 400)]
    end)
  end

  # The user is usually assigned by a hook that runs after this one, so the
  # metadata set at mount can still be empty. Filling it in on the first
  # callback that has it keeps every later line attributable.
  defp refresh_user(socket) do
    if is_nil(Logger.metadata()[:user]) do
      case user(socket) do
        nil -> :ok
        login -> Logger.metadata(user: login)
      end
    end
  end

  defp user(socket) do
    case socket.assigns do
      %{current_user: %{login: login}} -> login
      _no_user_yet -> nil
    end
  end

  defp filter(params) when is_map(params), do: Phoenix.Logger.filter_values(params)
  defp filter(:not_mounted_at_router), do: nil
  defp filter(params), do: params

  # A URI is noise at this level; the path and query are the part worth having.
  defp path(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: nil} -> uri
      %URI{path: p, query: nil} -> p
      %URI{path: p, query: q} -> p <> "?" <> q
    end
  end

  defp path(uri), do: inspect(uri)

  # Messages carry whole structs (a Block, a Submission); print the shape
  # rather than dumping the record into the log.
  defp summarize(message) when is_tuple(message) do
    message |> Tuple.to_list() |> Enum.map_join(", ", &summarize/1)
  end

  defp summarize(%module{id: id}), do: "%#{inspect(module)}{id: #{inspect(id)}}"
  defp summarize(%module{}), do: "%#{inspect(module)}{}"
  defp summarize(message), do: inspect(message, limit: 10, printable_limit: 200)

  defp async_outcome({:ok, _value}), do: :ok
  defp async_outcome({:exit, reason}), do: "exit: #{inspect(reason, limit: 10)}"
  defp async_outcome(other), do: inspect(other, limit: 5)
end
