import Config

config :membrane_rtp_plugin,
  vad_estimation_parameters: [
    n1: 2,
    n2: 2,
    n3: 2,
    medium_subunit_threshold: 2,
    long_subunit_threshold: 1,
    immediate_score_threshold: 0.1,
    medium_score_threshold: 0.1,
    long_score_threshold: 0.1
  ]
