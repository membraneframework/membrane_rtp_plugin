import Config

config :membrane_rtp_plugin,
  vad_estimation_parameters: %{
    immediate: %{
      subunits: 2,
      score_threshold: 0.1,
      lambda: 1
    },
    medium: %{
      subunits: 2,
      score_threshold: 0.1,
      subunit_threshold: 2,
      lambda: 1
    },
    long: %{
      subunits: 2,
      score_threshold: 0.1,
      subunit_threshold: 1,
      lambda: 1
    }
  }
