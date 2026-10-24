defmodule AthenaWeb.TeachingLive.InstructorComponents do
  @moduledoc """
  Shared presentation of an instructor (a coach, on a team).

  Cohort and team views used to render just `instructor.account.login`, which
  tells a reader nothing about who the person actually is. Everything needed
  for a proper name is already loaded - `Athena.Learning.Instructors.enrich_with_accounts/1`
  fills the virtual `account`, and `Athena.Identity.Accounts.get_accounts_map/1`
  preloads its `profile` - so this adds no queries.
  """
  use AthenaWeb, :html

  @doc """
  A chip naming one instructor: surname with initials, their post after a
  separator, and the full name plus login on hover.

  Falls back to the login when there is no profile, and to "Unknown" when the
  account itself could not be loaded (a deleted account still referenced by
  the join table).

  ## Examples

      <.instructor_chip :for={inst <- @cohort.instructors} instructor={inst} />
  """
  attr :instructor, :map, required: true
  attr :class, :any, default: nil

  def instructor_chip(assigns) do
    assigns =
      assigns
      |> assign(:name, short_name(assigns.instructor))
      |> assign(:post, post(assigns.instructor))
      |> assign(:hover, hover_text(assigns.instructor))

    ~H"""
    <span
      class={[
        "inline-flex items-baseline gap-1.5 badge badge-sm font-bold",
        "bg-base-200 text-base-content/80 border-base-300",
        @class
      ]}
      title={@hover}
    >
      {@name}
      <span :if={@post} class="font-normal text-base-content/60">· {@post}</span>
    </span>
    """
  end

  @doc """
  The instructor's post (their `title`), or `nil` when it is blank.
  """
  @spec post(map()) :: String.t() | nil
  def post(%{title: title}) when is_binary(title) do
    case String.trim(title) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def post(_instructor), do: nil

  @doc """
  "Surname N. P." when a profile is loaded, the login when it is not.
  """
  @spec short_name(map()) :: String.t()
  def short_name(%{account: %{profile: %{} = profile} = account}) do
    initials =
      [profile.first_name, profile.patronymic]
      |> Enum.map(&initial/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    case {blank_to_nil(profile.last_name), initials} do
      {nil, ""} -> account.login
      {nil, initials} -> initials
      {last, ""} -> last
      {last, initials} -> "#{last} #{initials}"
    end
  end

  def short_name(%{account: %{login: login}}), do: login
  def short_name(_instructor), do: gettext("Unknown")

  @doc """
  The full, unabbreviated name with the login in brackets, for a tooltip.
  """
  @spec hover_text(map()) :: String.t() | nil
  def hover_text(%{account: %{profile: %{} = profile} = account}) do
    full =
      [profile.last_name, profile.first_name, profile.patronymic]
      |> Enum.map(&blank_to_nil/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    if full == "", do: account.login, else: "#{full} (#{account.login})"
  end

  def hover_text(%{account: %{login: login}}), do: login
  def hover_text(_instructor), do: nil

  defp initial(name) do
    case blank_to_nil(name) do
      nil -> nil
      value -> String.slice(value, 0, 1) <> "."
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
