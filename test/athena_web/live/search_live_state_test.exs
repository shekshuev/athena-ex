defmodule AthenaWeb.SearchLiveStateTest do
  use AthenaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias AthenaWeb.SearchLive

  setup do
    socket = %Phoenix.LiveView.Socket{
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{__changed__: %{}, flash: %{}, current_user: nil}
    }

    {:ok, socket, _} = SearchLive.mount(%{}, %{}, socket)
    %{socket: Phoenix.Component.assign(socket, open?: true, generation: 2, status: :loading)}
  end

  test "late success or failure cannot replace a newer generation", %{socket: socket} do
    page = %{items: [], next_cursor: nil}

    for result <- [{:ok, {:ok, page}}, {:ok, {:error, :timeout}}, {:exit, :shutdown}] do
      assert {:noreply, ^socket} = SearchLive.handle_async({:search, 1, :replace}, result, socket)
    end
  end

  test "late results cannot reopen a closed palette", %{socket: socket} do
    socket = Phoenix.Component.assign(socket, open?: false)

    assert {:noreply, ^socket} =
             SearchLive.handle_async(
               {:search, 2, :replace},
               {:ok, {:ok, %{items: [], next_cursor: nil}}},
               socket
             )
  end

  test "a failed request has a retry state and never becomes an empty result", %{socket: socket} do
    {:noreply, socket} =
      SearchLive.handle_async({:search, 2, :replace}, {:ok, {:error, :timeout}}, socket)

    html = render_component(&SearchLive.render/1, Map.delete(socket.assigns, :__changed__))
    doc = LazyHTML.from_fragment(html)
    assert LazyHTML.query(doc, "#global-search-error") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#global-search-empty") |> Enum.count() == 0
  end

  test "failed continuation keeps the cursor for retry", %{socket: socket} do
    socket =
      Phoenix.Component.assign(socket,
        status: :loading_more,
        cursor: %{query: "needle"},
        result_count: 5
      )

    {:noreply, socket} = SearchLive.handle_async({:search, 2, :more}, {:exit, :failure}, socket)
    html = render_component(&SearchLive.render/1, Map.delete(socket.assigns, :__changed__))
    doc = LazyHTML.from_fragment(html)
    assert LazyHTML.query(doc, "#global-search-more-error") |> Enum.count() == 1
    assert LazyHTML.query(doc, "#global-search-more:not([disabled])") |> Enum.count() == 1
    assert socket.assigns.result_count == 5
    assert socket.assigns.cursor == %{query: "needle"}
  end
end
