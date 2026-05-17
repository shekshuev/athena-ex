# .credo.exs
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "src/",
          "test/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/test/",
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
