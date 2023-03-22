import Config

config :membrane_rtp_plugin,
  fir_throttle_duration_ms: 500,
  vad_estimation_parameters: [
    n1: 1,
    n2: 10,
    n3: 7,

    immediate_score_threshold: 0,
    medium_score_threshold: 20,
    long_score_threshold: 20,

    medium_subunit_threshold: 1,
    long_subunit_threshold: 3,
  ]
