# Expected failure: only the six new reply-coordination cases, against the
# pre-fix adapter/protocol loaded in this VM. Checkout/build files stay intact.
for module <- [Parlora.Providers.Phonic, Parlora.Providers.Phonic.Protocol],
    do: Code.ensure_loaded!(module)

Code.compiler_options(ignore_module_conflict: true)

for path <- ["lib/parlora/providers/phonic/protocol.ex", "lib/parlora/providers/phonic.ex"] do
  {source, 0} = System.cmd("git", ["show", "6d174ad:#{path}"])
  Code.compile_string(source, "before/#{path}")
end

Code.require_file("test/test_helper.exs")
ExUnit.configure(exclude: [:test], include: [:reply_coordination])
Code.require_file("test/phonic_adapter_test.exs")
