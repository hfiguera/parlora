# Expected: six of eight shutdown cases fail against the pre-fix adapter.
# Historical code is loaded only in this VM; checkout and build files stay intact.
Code.ensure_loaded!(Parlora.Providers.Phonic)
Code.compiler_options(ignore_module_conflict: true)
{source, 0} = System.cmd("git", ["show", "70abe2b:lib/parlora/providers/phonic.ex"])
Code.compile_string(source, "before-shutdown-fix/phonic.ex")
Code.require_file("test/test_helper.exs")
Code.require_file("test/phonic_shutdown_test.exs")
