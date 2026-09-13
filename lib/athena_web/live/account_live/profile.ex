defmodule AthenaWeb.AccountLive.Profile do
  @moduledoc """
  Self-service account page: personal info, avatar, password, and (once
  gamification lands) a personal "Achievements" tab.
  """
  use AthenaWeb, :live_view

  alias Athena.{Identity, Media, Gamification, Learning}
  alias Athena.Identity.Profile

  defmodule PasswordForm do
    @moduledoc """
    Embedded schema for the self-service password change form.

    Unlike the forced-password-change flow, this requires the current
    password since the account isn't already in a "must change" state.
    """
    use Ecto.Schema
    import Ecto.Changeset
    use Gettext, backend: AthenaWeb.Gettext
    alias Athena.Identity

    @primary_key false
    embedded_schema do
      field :current_password, :string
      field :password, :string
      field :password_confirmation, :string
    end

    @doc """
    Builds a changeset for the password change form.
    """
    def changeset(data \\ %__MODULE__{}, attrs) do
      data
      |> cast(attrs, [:current_password, :password, :password_confirmation])
      |> validate_required([:current_password, :password, :password_confirmation],
        message: dgettext_noop("errors", "is required")
      )
      |> validate_format(:password, Identity.password_regex(),
        message:
          dgettext_noop(
            "errors",
            "must be at least 8 characters long and contain at least one uppercase letter, one lowercase letter, one number, and one special character"
          )
      )
      |> validate_confirmation(:password,
        message: dgettext_noop("errors", "does not match password")
      )
    end
  end

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_user
    profile = account.profile || %Profile{}

    socket =
      socket
      |> assign(:profile_form, to_form(Profile.changeset(profile, %{}), as: "profile"))
      |> assign(
        :password_form,
        to_form(PasswordForm.changeset(%PasswordForm{}, %{}), as: "password")
      )
      |> allow_upload(:avatar,
        accept: ~w(.jpg .jpeg .png .gif .webp),
        max_entries: 1,
        max_file_size: 5 * 1024 * 1024,
        external: &presign_avatar/2
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] == "achievements", do: "achievements", else: "profile"

    socket =
      if tab == "achievements" do
        assign_achievements(socket)
      else
        socket
      end

    {:noreply, assign(socket, :tab, tab)}
  end

  defp assign_achievements(socket) do
    account = socket.assigns.current_user
    total_xp = Gamification.total_xp(account.id)
    level = Gamification.level_for_xp(total_xp)
    streak = Gamification.streak(account.id)
    awards = Gamification.list_awards(account.id)

    socket
    |> assign(:total_xp, total_xp)
    |> assign(:level, level)
    |> assign(:streak, streak)
    |> assign(:awards, awards)
    |> assign(:league, league_widget_data(account))
    |> assign(:show_in_league, show_in_league?(account))
  end

  defp league_widget_data(account) do
    enrollments = Learning.list_student_enrollments(account.id)

    case Enum.find(enrollments, &(&1.cohort_id && &1.cohort.type == :academic)) do
      nil ->
        nil

      enrollment ->
        standings = Gamification.visible_standings(enrollment.cohort_id, account.id)
        accounts = Identity.get_accounts_map(Enum.map(standings, & &1.account_id))

        standings =
          Enum.map(standings, fn entry ->
            login = accounts[entry.account_id] && accounts[entry.account_id].login
            Map.put(entry, :login, login)
          end)

        %{
          cohort_id: enrollment.cohort_id,
          cohort_name: enrollment.cohort.name,
          standings: standings
        }
    end
  end

  defp show_in_league?(account) do
    metadata = (account.profile && account.profile.metadata) || %{}
    Map.get(metadata, "show_in_league", true)
  end

  @impl true
  def handle_event("validate_profile", %{"profile" => params}, socket) do
    account = socket.assigns.current_user
    profile = account.profile || %Profile{}

    changeset =
      profile
      |> Profile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :profile_form, to_form(changeset, as: "profile"))}
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    account = socket.assigns.current_user

    case Identity.update_own_profile(account, params) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:current_user, %{account | profile: profile})
         |> assign(:profile_form, to_form(Profile.changeset(profile, %{}), as: "profile"))
         |> put_flash(:info, gettext("Profile updated successfully"))}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, as: "profile"))}
    end
  end

  def handle_event("toggle_league_visibility", _params, socket) do
    account = socket.assigns.current_user
    metadata = (account.profile && account.profile.metadata) || %{}
    new_metadata = Map.put(metadata, "show_in_league", !show_in_league?(account))
    attrs = %{"metadata" => new_metadata}

    # A bootstrap admin created via `Athena.Release.create_admin/2` has no
    # Profile row yet — creating one here needs the required name fields,
    # so fall back to the login rather than failing the toggle outright.
    attrs =
      if account.profile,
        do: attrs,
        else: Map.merge(attrs, %{"first_name" => account.login, "last_name" => account.login})

    case Identity.update_own_profile(account, attrs) do
      {:ok, updated_profile} ->
        updated_account = %{account | profile: updated_profile}

        {:noreply,
         socket
         |> assign(:current_user, updated_account)
         |> assign(:show_in_league, show_in_league?(updated_account))
         |> assign(:league, league_widget_data(updated_account))}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  def handle_event("validate_avatar", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_avatar", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :avatar, ref)}
  end

  def handle_event("save_avatar", _params, socket) do
    account = socket.assigns.current_user

    results =
      consume_uploaded_entries(socket, :avatar, fn meta, entry ->
        file_attrs = %{
          "bucket" => meta.bucket,
          "key" => meta.key,
          "original_name" => entry.client_name,
          "mime_type" => entry.client_type,
          "size" => entry.client_size,
          "context" => "avatar",
          "owner_id" => account.id
        }

        case Media.create_file(file_attrs) do
          {:ok, _file} -> {:ok, {:ok, meta.url_for_saved_entry}}
          {:error, err} -> {:ok, {:error, err}}
        end
      end)

    case results do
      [{:ok, avatar_url}] ->
        case Identity.update_own_profile(account, %{"avatar_url" => avatar_url}) do
          {:ok, profile} ->
            {:noreply,
             socket
             |> assign(:current_user, %{account | profile: profile})
             |> put_flash(:info, gettext("Avatar updated successfully"))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Could not save the avatar"))}
        end

      [{:error, _reason}] ->
        {:noreply, put_flash(socket, :error, gettext("Avatar upload failed"))}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_event("validate_password", %{"password" => params}, socket) do
    changeset =
      %PasswordForm{}
      |> PasswordForm.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :password_form, to_form(changeset, as: "password"))}
  end

  def handle_event("save_password", %{"password" => params}, socket) do
    changeset =
      %PasswordForm{}
      |> PasswordForm.changeset(params)
      |> Map.put(:action, :insert)

    if changeset.valid? do
      current_password = Ecto.Changeset.get_field(changeset, :current_password)
      new_password = Ecto.Changeset.get_field(changeset, :password)
      account = socket.assigns.current_user

      case Identity.change_password(account, current_password, new_password) do
        {:ok, _updated_account} ->
          {:noreply,
           socket
           |> assign(
             :password_form,
             to_form(PasswordForm.changeset(%PasswordForm{}, %{}), as: "password")
           )
           |> put_flash(:info, gettext("Password updated successfully"))}

        {:error, :invalid_old_password} ->
          changeset =
            changeset
            |> Ecto.Changeset.add_error(:current_password, gettext("is incorrect"))
            |> Map.put(:action, :insert)

          {:noreply, assign(socket, :password_form, to_form(changeset, as: "password"))}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not update the password"))}
      end
    else
      {:noreply, assign(socket, :password_form, to_form(changeset, as: "password"))}
    end
  end

  defp presign_avatar(entry, socket) do
    case Media.prepare_avatar_upload(socket.assigns.current_user.id, entry.client_name) do
      {:ok, meta} -> {:ok, meta, socket}
      {:error, _reason} -> {:error, %{reason: gettext("Could not generate upload URL")}, socket}
    end
  end

  defp level_progress_percent(_xp, %{ceiling: nil}), do: 100

  defp level_progress_percent(xp, %{floor: floor, ceiling: ceiling}) do
    round((xp - floor) / (ceiling - floor) * 100)
  end

  defp initials(nil), do: "?"

  defp initials(login) when is_binary(login) do
    login |> String.slice(0, 2) |> String.upcase()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <div>
        <h1 class="text-3xl font-display font-black uppercase tracking-tight text-base-content">
          {gettext("My Account")}
        </h1>
        <p class="text-base-content/60 font-medium mt-1">
          {gettext("Manage your personal information, avatar, and security settings.")}
        </p>
      </div>

      <div role="tablist" class="tabs tabs-lift">
        <.link
          patch={~p"/me?tab=profile"}
          role="tab"
          class={["tab font-bold", @tab == "profile" && "tab-active"]}
          id="profile-tab-link"
        >
          {gettext("Profile")}
        </.link>
        <.link
          patch={~p"/me?tab=achievements"}
          role="tab"
          class={["tab font-bold", @tab == "achievements" && "tab-active"]}
          id="achievements-tab-link"
        >
          {gettext("Achievements")}
        </.link>
      </div>

      <div :if={@tab == "profile"} class="space-y-6">
        <div class="card bg-base-100 border border-base-300 rounded-sm">
          <div class="card-body">
            <h2 class="font-display font-black uppercase text-sm text-base-content/70 mb-4">
              {gettext("Avatar")}
            </h2>

            <form
              id="avatar-form"
              phx-change="validate_avatar"
              phx-submit="save_avatar"
              class="flex items-center gap-6"
            >
              <.avatar
                src={@current_user.profile && @current_user.profile.avatar_url}
                initials={initials(@current_user.login)}
                alt={gettext("Avatar")}
                size="w-16"
              />

              <div class="flex-1 min-w-0">
                <label
                  for={@uploads.avatar.ref}
                  class="btn btn-outline btn-sm font-bold cursor-pointer"
                >
                  <.icon name="hero-camera" class="size-4" />
                  {gettext("Choose image")}
                </label>
                <.live_file_input upload={@uploads.avatar} class="hidden" />

                <div :for={entry <- @uploads.avatar.entries} class="mt-3 flex items-center gap-3">
                  <span class="text-sm font-medium truncate">{entry.client_name}</span>
                  <progress class="progress progress-primary w-16" value={entry.progress} max="100" />
                  <.icon_button
                    type="button"
                    phx-click="cancel_avatar"
                    phx-value-ref={entry.ref}
                    icon="hero-x-mark"
                    label={gettext("Cancel")}
                    variant="danger"
                  />
                </div>

                <.button
                  :if={@uploads.avatar.entries != []}
                  type="submit"
                  variant="primary"
                  size="xs"
                  class="mt-2"
                  phx-disable-with={gettext("Uploading...")}
                >
                  {gettext("Save avatar")}
                </.button>

                <div
                  :for={{_ref, msg} <- @uploads.avatar.errors}
                  class="text-error text-xs font-bold mt-2"
                >
                  {msg}
                </div>
              </div>
            </form>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300 rounded-sm">
          <div class="card-body">
            <h2 class="font-display font-black uppercase text-sm text-base-content/70 mb-4">
              {gettext("Personal Information")}
            </h2>

            <.form
              for={@profile_form}
              id="profile-form"
              phx-change="validate_profile"
              phx-submit="save_profile"
              class="space-y-4"
            >
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input
                  field={@profile_form[:last_name]}
                  type="text"
                  label={gettext("Last Name")}
                  required
                />
                <.input
                  field={@profile_form[:first_name]}
                  type="text"
                  label={gettext("First Name")}
                  required
                />
              </div>
              <.input
                field={@profile_form[:patronymic]}
                type="text"
                label={gettext("Patronymic")}
              />

              <div class="flex justify-end">
                <.button type="submit" variant="primary" phx-disable-with={gettext("Saving...")}>
                  {gettext("Save changes")}
                </.button>
              </div>
            </.form>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300 rounded-sm">
          <div class="card-body">
            <h2 class="font-display font-black uppercase text-sm text-base-content/70 mb-4">
              {gettext("Password")}
            </h2>

            <.form
              for={@password_form}
              id="password-form"
              phx-change="validate_password"
              phx-submit="save_password"
              class="space-y-4"
            >
              <.input
                field={@password_form[:current_password]}
                type="password"
                label={gettext("Current Password")}
                required
              />
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.input
                  field={@password_form[:password]}
                  type="password"
                  label={gettext("New Password")}
                  required
                />
                <.input
                  field={@password_form[:password_confirmation]}
                  type="password"
                  label={gettext("Confirm New Password")}
                  required
                />
              </div>

              <div class="flex justify-end">
                <.button type="submit" variant="primary" phx-disable-with={gettext("Saving...")}>
                  {gettext("Update password")}
                </.button>
              </div>
            </.form>
          </div>
        </div>
      </div>

      <div :if={@tab == "achievements"} class="space-y-6">
        <div class="card bg-base-100 border border-base-300 rounded-sm">
          <div class="card-body flex-row items-center gap-6 flex-wrap">
            <div class="flex items-center justify-center w-20 h-20 rounded-full bg-primary/10 border border-primary/20 shrink-0">
              <span class="text-2xl font-display font-black text-primary">{@level.level}</span>
            </div>
            <div class="flex-1 min-w-0">
              <div class="text-xs font-black uppercase tracking-widest text-base-content/50">
                {gettext("Level %{level}", level: @level.level)}
              </div>
              <div class="text-3xl font-display font-black">
                {gettext("%{xp} XP", xp: @total_xp)}
              </div>
              <div :if={@level.ceiling} class="mt-2">
                <div class="w-full max-w-xs bg-base-300 rounded-full h-2 overflow-hidden">
                  <div
                    class="h-full bg-primary transition-all duration-300"
                    style={"width: #{level_progress_percent(@total_xp, @level)}%"}
                  >
                  </div>
                </div>
                <div class="text-xs text-base-content/50 mt-1">
                  {gettext("%{remaining} XP to level %{next}",
                    remaining: @level.ceiling - @total_xp,
                    next: @level.level + 1
                  )}
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300 rounded-sm">
          <div class="card-body flex-row items-center gap-4">
            <div class="flex items-center justify-center w-14 h-14 rounded-full bg-warning/10 border border-warning/20 shrink-0">
              <.icon name="hero-fire" class="size-7 text-warning" />
            </div>
            <div>
              <div class="text-2xl font-display font-black">
                {ngettext(
                  "%{count} week streak",
                  "%{count} week streak",
                  @streak.current_weeks,
                  count: @streak.current_weeks
                )}
              </div>
              <div class="text-xs text-base-content/50">
                {gettext("Best: %{count} weeks", count: @streak.longest_weeks)}
              </div>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300 rounded-sm">
          <div class="card-body">
            <h2 class="font-display font-black uppercase text-sm text-base-content/70 mb-4">
              {gettext("Badges")}
            </h2>

            <div :if={@awards == []} class="text-base-content/50 text-sm">
              {gettext("No badges yet — keep practicing!")}
            </div>

            <div :if={@awards != []} class="grid grid-cols-2 sm:grid-cols-4 gap-4">
              <div
                :for={award <- @awards}
                class="flex flex-col items-center text-center gap-2 p-4 bg-base-200/50 rounded-sm border border-base-200"
                title={award.badge.description}
              >
                <div class="flex items-center justify-center w-12 h-12 rounded-full bg-primary/10 border border-primary/20">
                  <.icon name={award.badge.icon} class="size-6 text-primary" />
                </div>
                <div class="text-xs font-bold truncate w-full">{award.badge.title}</div>
              </div>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 border border-base-300 rounded-sm">
          <div class="card-body">
            <div class="flex items-center justify-between flex-wrap gap-3 mb-4">
              <h2 class="font-display font-black uppercase text-sm text-base-content/70">
                {gettext("Weekly League")}
              </h2>
              <label class="flex items-center gap-2 cursor-pointer">
                <span class="text-xs text-base-content/60">
                  {gettext("Show me to others in the league")}
                </span>
                <input
                  type="checkbox"
                  class="toggle toggle-sm toggle-primary"
                  checked={@show_in_league}
                  phx-click="toggle_league_visibility"
                />
              </label>
            </div>

            <div :if={!@league} class="text-base-content/50 text-sm">
              {gettext("Join an academic cohort to see a weekly league here.")}
            </div>

            <div :if={@league}>
              <div class="text-xs text-base-content/50 mb-3">{@league.cohort_name}</div>
              <ul class="space-y-1">
                <li
                  :for={entry <- @league.standings}
                  class={[
                    "flex items-center justify-between px-3 py-2 rounded-sm text-sm",
                    entry.account_id == @current_user.id && "bg-primary/10 font-bold",
                    entry.tier == :top && "border-l-4 border-warning"
                  ]}
                >
                  <span>
                    #{entry.rank}
                    {if entry.account_id == @current_user.id,
                      do: gettext("You"),
                      else: entry.login}
                  </span>
                  <span>{entry.weekly_xp} XP</span>
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
