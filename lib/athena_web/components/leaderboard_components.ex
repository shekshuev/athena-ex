defmodule AthenaWeb.LeaderboardComponents do
  @moduledoc """
  The competition leaderboard's table, shared by the standalone
  `AthenaWeb.LearnLive.Leaderboard` page and the player's leaderboard
  modal so a team reads the same board wherever they look at it.
  """
  use Phoenix.Component
  use Gettext, backend: AthenaWeb.Gettext

  import AthenaWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, required: true
  attr :board, :list, required: true

  @doc """
  Ranks teams by score, disqualified ones greyed out at the bottom.

  Rows are only clickable when `row_click` is given - the player's modal
  has nowhere to open a roster into, so it leaves it out and the rows stay
  inert rather than advertising an action that does nothing.
  """
  attr :row_click, :string,
    default: nil,
    doc: "name of the `phx-click` event a row sends, with `team_id` as its value"

  def board_table(assigns) do
    ~H"""
    <table id={@id} class="w-full text-lg">
      <thead class="text-xs font-bold uppercase tracking-widest text-base-content/50 border-b border-base-200 text-left">
        <tr>
          <th class="py-4 px-2 w-16 text-center">#</th>
          <th class="py-4 px-2">{gettext("Team")}</th>
          <th class="py-4 px-2 text-right">{gettext("Score")}</th>
        </tr>
      </thead>
      <tbody>
        <%= if @board == [] do %>
          <tr>
            <td colspan="3" class="text-center py-16 text-base-content/40 italic font-medium">
              {gettext("This leaderboard is currently empty.")}
            </td>
          </tr>
        <% else %>
          <%= for {team, index} <- Enum.with_index(@board, 1) do %>
            <tr
              phx-click={@row_click}
              phx-value-team_id={team.team_id}
              class={[
                "border-b border-base-200 transition-colors group",
                @row_click && "hover:bg-base-200/50 cursor-pointer",
                (index == 1 and not team.is_disqualified) && "bg-primary/5",
                team.is_disqualified && "opacity-50 grayscale bg-error/5"
              ]}
            >
              <td class="py-5 px-2 text-center font-bold text-base-content/40">
                <%= if team.is_disqualified do %>
                  <.icon name="hero-no-symbol" class="size-5 text-error" />
                <% else %>
                  {index}
                <% end %>
              </td>
              <td class="py-5 px-2 font-bold text-base-content flex items-center gap-3">
                <span class={if index == 1 and not team.is_disqualified, do: "text-primary", else: ""}>
                  {team.team_name}
                </span>
              </td>
              <td class="py-5 px-2 text-right font-mono font-bold text-primary">
                <%= if team.is_disqualified do %>
                  <span class="badge badge-error badge-sm font-bold uppercase tracking-widest border-0 bg-error/10 text-error">
                    {gettext("Disqualified")}
                  </span>
                <% else %>
                  {team.total_score}
                <% end %>
              </td>
            </tr>
          <% end %>
        <% end %>
      </tbody>
    </table>
    """
  end
end
