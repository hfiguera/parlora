{opts, args, []} =
  OptionParser.parse(System.argv(),
    strict: [
      observability: :boolean,
      microphone: :boolean,
      any_doctor: :boolean,
      phonic_native_conversation: :boolean,
      ambience: :string
    ]
  )

case args do
  [directory, clips] ->
    report =
      BookingDesk.Run.run(directory, clips,
        mode: if(opts[:microphone], do: :microphone, else: :replay),
        observability: opts[:observability],
        any_doctor: opts[:any_doctor] || false,
        phonic_native_conversation: Keyword.get(opts, :phonic_native_conversation, true),
        ambience: opts[:ambience]
      )

    if opts[:observability], do: Process.sleep(4_000)
    unless report.passed || opts[:microphone], do: System.halt(1)

  _ ->
    raise "Usage: mix run run.exs OUTPUT_DIRECTORY CLIPS_DIRECTORY [--observability] [--microphone] [--any-doctor] [--no-phonic-native-conversation] [--ambience MANIFEST]"
end
