# Separate diagnostic VM only; never load into a running application.
# Expected exit: test failure, because this is the negative control.
Code.compiler_options(ignore_module_conflict: true)
{source, 0} = System.cmd("git", ["show", "801f7baa15efe279c0943ea512e3a64c27a8143a:lib/parlora/channels/browser/media.ex"])
Code.compile_string(source)
Mix.Task.run("test", ["test/browser_audio_property_test.exs", "--seed", "20260921"])
