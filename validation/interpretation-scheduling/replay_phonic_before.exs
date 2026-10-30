# Run from the repository root with MIX_ENV=test mix run. Three failed
# regressions are expected: the pre-fix adapter never requests the late reply.
# Only this VM's loaded module changes; the checkout and build files are intact.
Code.ensure_loaded!(Parlora.Providers.Phonic)
Code.compiler_options(ignore_module_conflict: true)
{source, 0} = System.cmd("git", ["show", "7616fa5:lib/parlora/providers/phonic.ex"])
Code.compile_string(source, "before-fix/phonic.ex")
Code.require_file("test/test_helper.exs")
Code.require_file("test/phonic_session_test.exs")
Code.require_file("test/phonic_adapter_test.exs")
