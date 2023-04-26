import Config

config :membrane_rtp_plugin,
  fir_throttle_duration_ms: 500,
  vad_estimation_parameters: %{
    immediate: %{
      subunits: 1,
      score_threshold: 0,
      lambda: 1
    },
    medium: %{
      subunits: 10,
      score_threshold: 20,
      subunit_threshold: 1,
      lambda: 24
    },
    long: %{
      subunits: 7,
      score_threshold: 20,
      subunit_threshold: 3,
      lambda: 47
    }
  }

import_config "#{config_env()}.exs"
