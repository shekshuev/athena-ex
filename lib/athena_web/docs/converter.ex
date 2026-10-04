defmodule AthenaWeb.Docs.Converter do
  @moduledoc """
  Markdown to HTML for `AthenaWeb.Docs`, at compile time.

  Before the markdown is rendered (MDEx: GitHub-flavoured tables, task
  lists, `> [!NOTE]`-style callouts, heading anchors), every `:ui[Msgid]`
  is replaced by that interface label as the page's language shows it -
  the `default` gettext translation of `Msgid` - wrapped in
  `<span class="ui-label">`. A `Msgid` that the interface doesn't have
  (it isn't in `priv/gettext/default.pot`) fails the build, so the
  documentation can never name a button the interface doesn't show, and
  never word it differently from the translation.
  """

  @ui_label ~r/:ui\[([^\]]+)\]/
  @pot "priv/gettext/default.pot"

  @doc false
  def convert(path, body, _attrs, _opts) do
    lang = lang(path)

    body
    |> resolve_ui_labels(lang, path)
    |> MDEx.to_html!(
      extension: [
        table: true,
        strikethrough: true,
        tasklist: true,
        autolink: true,
        alerts: true,
        header_id_prefix: ""
      ],
      render: [unsafe: true]
    )
  end

  @doc """
  Replaces every `:ui[Msgid]` in `markdown` with the label in `lang`.
  Raises if a `Msgid` is not an interface string.
  """
  @spec resolve_ui_labels(String.t(), String.t(), String.t()) :: String.t()
  def resolve_ui_labels(markdown, lang, path \\ "(inline)") do
    Regex.replace(@ui_label, markdown, fn _, msgid ->
      unless MapSet.member?(known_msgids(), msgid) do
        raise ArgumentError, """
        unknown interface label :ui[#{msgid}] in #{path}.
        Every :ui[...] must be an existing msgid of #{@pot} - copy it from the interface's source.
        """
      end

      label =
        Gettext.with_locale(AthenaWeb.Gettext, lang, fn ->
          Gettext.dgettext(AthenaWeb.Gettext, "default", msgid)
        end)

      ~s(<span class="ui-label">#{Phoenix.HTML.html_escape(label) |> Phoenix.HTML.safe_to_string()}</span>)
    end)
  end

  defp lang(path) do
    case Regex.run(~r"priv/docs/([a-z]{2})/", path) do
      [_, lang] -> lang
      _ -> "en"
    end
  end

  # Read once per compilation; `AthenaWeb.Docs` lists the .pot as an
  # external resource, so changing it recompiles the documentation.
  defp known_msgids do
    case Process.get({__MODULE__, :msgids}) do
      nil ->
        msgids = @pot |> File.read!() |> parse_msgids()
        Process.put({__MODULE__, :msgids}, msgids)
        msgids

      msgids ->
        msgids
    end
  end

  defp parse_msgids(pot) do
    ~r/^msgid "(.*)"$/m
    |> Regex.scan(pot)
    |> Enum.map(fn [_, msgid] -> String.replace(msgid, ~S(\"), ~S(")) end)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end
end
