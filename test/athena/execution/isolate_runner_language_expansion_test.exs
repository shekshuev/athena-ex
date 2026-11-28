defmodule Athena.Execution.IsolateRunnerLanguageExpansionTest do
  use ExUnit.Case, async: false

  alias Athena.Execution.{IsolateRunner, LanguageConfig}

  @moduletag :isolate
  @moduletag timeout: 180_000

  # Run in the matching runner image with --only runner_family:<family>.
  # Missing isolate/toolchains are failures, never implicit skips.
  @programs [
    {"c", :compiled,
     "#include <stdio.h>\nint main(void){char s[256]; fgets(s,sizeof(s),stdin); printf(\"Hello %s\",s);}",
     "int main(void){while(1){} }"},
    {"javascript", :script,
     "const fs=require('fs'); console.log('Hello '+fs.readFileSync(0,'utf8').trim());",
     "while(true){}"},
    {"typescript", :script,
     "const fs=require('fs'); const input: string=fs.readFileSync(0,'utf8').trim(); console.log('Hello '+input);",
     "while(true){}"},
    {"go", :compiled,
     "package main\nimport(\"fmt\";\"bufio\";\"os\")\nfunc main(){s:=bufio.NewScanner(os.Stdin);s.Scan();fmt.Println(\"Hello \"+s.Text())}",
     "package main\nfunc main(){for{}}"},
    {"swift", :compiled, "import Foundation\nprint(\"Hello \" + readLine()!)", "while true {}"},
    {"rust", :compiled,
     "use std::io; fn main(){let mut s=String::new();io::stdin().read_line(&mut s).unwrap();println!(\"Hello {}\",s.trim());}",
     "fn main(){loop{std::hint::spin_loop();}}"},
    {"zig", :compiled,
     "extern \"c\" fn read(c_int, [*]u8, usize) isize; extern \"c\" fn write(c_int, [*]const u8, usize) isize; pub fn main() void { var buf: [256]u8=undefined; const n=read(0,&buf,buf.len); if(n<=0) return; _=write(1,\"Hello \",6); _=write(1,&buf,@intCast(n)); }",
     "pub fn main() void { while(true) { asm volatile (\"\"); } }"},
    {"java", :jvm,
     "import java.util.Scanner; public class Main { public static void main(String[] args){System.out.println(\"Hello \"+new Scanner(System.in).nextLine());}}",
     "public class Main { public static void main(String[] args){while(true){}}}"},
    {"kotlin", :jvm, "fun main() { println(\"Hello \" + readln()) }",
     "fun main() { while(true) {} }"},
    {"csharp", :dotnet,
     "using System; class MainClass { static void Main(){Console.WriteLine(\"Hello \"+Console.ReadLine());}}",
     "class MainClass { static void Main(){while(true){}} }"}
  ]

  for {language, family, hello, loop} <- @programs do
    @tag runner_family: family
    test "#{language} echoes Unicode stdin", context do
      assert {:ok, result} = run(unquote(language), unquote(hello), "Мир 🌍", context)
      assert result.meta["exitcode"] == "0"
      assert result.meta["status"] in [nil, "OK"]
      assert result.stdout == "Hello Мир 🌍"
    end

    @tag runner_family: family
    test "#{language} enforces runtime timeout", context do
      assert {:ok, result} = run(unquote(language), unquote(loop), nil, context)
      assert result.meta["status"] == "TO"
    end

    if language != "javascript" do
      @tag runner_family: family
      test "#{language} reports compilation errors", context do
        code =
          if unquote(language) == "typescript",
            do: "const value: number = 'not a number'; console.log(value);",
            else: "this is not valid source !!!"

        assert {:ok, result} = run(unquote(language), code, nil, context)
        assert result.meta["status"] == "CE"
        assert result.stdout == ""
        assert String.trim(result.stderr) != ""
      end
    end
  end

  @tag runner_family: :script
  test "Node cannot read host account files", context do
    code =
      "const fs=require('fs'); try { console.log(fs.readFileSync('/etc/passwd','utf8')); } catch(e) { console.log('ACCESS DENIED'); }"

    assert {:ok, result} = run("javascript", code, nil, context)
    assert result.meta["exitcode"] == "0"
    assert result.stdout == "ACCESS DENIED"
  end

  defp run(language, code, input, _context) do
    # These tests are serial and use a box outside the legacy suites' ranges.
    ctx = %IsolateRunner.Context{
      box_id: 750,
      lang_config: LanguageConfig.get(language),
      time_limit: 2.0,
      memory_limit: 262_144
    }

    assert File.exists?("/usr/bin/isolate"),
           "Run :isolate tests inside a privileged runner image with the selected family's toolchains"

    IsolateRunner.run_test(code, input, ctx)
  end
end
