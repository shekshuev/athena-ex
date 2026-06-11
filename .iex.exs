Application.put_env(:elixir, :ansi_enabled, true)
import_if_available(Ecto)
import_if_available(Ecto.Query)
import_if_available(Ecto.Changeset)
# Phoenix Support
import_if_available(Plug.Conn)
import_if_available(Phoenix.HTML)

# last = IO.ANSI.yellow() <> "➤➤" <> IO.ANSI.reset()

eval_result = [:light_yellow]
eval_error = [:red, :bright]
eval_info = [:blue, :bright]

IEx.configure(
  colors: [
    syntax_colors: [
      number: :light_yellow,
      atom: :light_cyan,
      string: :light_black,
      boolean: [:light_blue],
      nil: [:magenta, :bright]
    ],
    ls_directory: :cyan,
    ls_device: :yellow,
    doc_code: :green,
    doc_inline_code: :magenta,
    doc_headings: [:cyan, :underline],
    doc_title: [:green, :bright, :underline],
    eval_result: eval_result,
    eval_error: eval_error,
    eval_info: eval_info
  ],
  inspect: [
    width: 100,
    limit: :infinity,
    charlists: :as_lists
  ],
  width: 100,
  history_size: 30,
  # struct: true,
  # pretty: true,
  default_prompt:
    [
      # ANSI CHA, move cursor to column 1
      # "\e[G",
      :light_magenta,
      # plain string
      "[%counter]",
      "-%prefix",
      "-➤",
      :white,
      :reset
    ]
    |> IO.ANSI.format()
    |> IO.chardata_to_string()
)

alias Athena.Content
alias Athena.Identity
alias Athena.Learning
alias Athena.Repo
