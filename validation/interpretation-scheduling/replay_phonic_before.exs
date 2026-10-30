# Run from the repository root with MIX_ENV=test mix run. Three failed
# regressions are expected: the pre-fix adapter never requests the late reply.
# Only this VM's loaded module changes; the checkout and build files are intact.
for module <- [Parlora.Providers.Phonic, Parlora.Providers.Phonic.Protocol],
    do: Code.ensure_loaded!(module)

Code.compiler_options(ignore_module_conflict: true)

for path <- ["lib/parlora/providers/phonic/protocol.ex", "lib/parlora/providers/phonic.ex"] do
  {source, 0} = System.cmd("git", ["show", "7616fa5:#{path}"])
  Code.compile_string(source, "before-fix/#{path}")
end

Code.require_file("test/test_helper.exs")

# Preserve the original three-failure proof as the current suite grows.
for path <- ["test/phonic_session_test.exs", "test/phonic_adapter_test.exs"] do
  {source, 0} = System.cmd("git", ["show", "6d174ad:#{path}"])
  Code.compile_string(source, "original-proof/#{path}")
end
