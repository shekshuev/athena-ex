# .credo.exs
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "src/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/web/"
        ],
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          ~r"/node_modules/",
          "test/stress_testing/"
        ]
      },
      checks: %{}
    }
  ]
}
