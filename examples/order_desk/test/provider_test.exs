defmodule OrderDesk.ProviderTest do
  use ExUnit.Case, async: true
  alias OrderDesk.Provider
  alias Parlora.{AudioFormat, Limits}

  test "provider burst profiles scale with the codec and preserve application overrides" do
    for module <- [Parlora.Providers.Gemini, Parlora.Providers.Grok],
        format <- [%AudioFormat{}, AudioFormat.pcmu()] do
      options =
        Provider.session_options({module, []},
          audio_format: format,
          limits: [max_jobs: 2]
        )

      assert {:ok, limits} = Limits.new(options[:limits], format)
      duration = if module == Parlora.Providers.Grok, do: 20_000, else: 10_000
      assert limits.provider_audio_queue_bytes == AudioFormat.bytes_for_ms(format, duration)
      assert limits.provider_audio_max_age_ms == duration + 1_000
      assert limits.max_jobs == 2
      assert limits.audio_queue_bytes == AudioFormat.bytes_for_ms(format, 200)
    end

    options =
      Provider.session_options({Parlora.Providers.Gemini, []},
        limits: [provider_audio_max_age_ms: 5_000]
      )

    assert options[:limits][:provider_audio_max_age_ms] == 5_000
  end

  test "OpenAI session limits are unchanged" do
    options = [limits: [max_jobs: 2]]
    assert Provider.session_options({Parlora.Providers.OpenAI, []}, options) == options
    assert Provider.session_options({Parlora.Providers.OpenAI, []}, []) == []
  end
end
