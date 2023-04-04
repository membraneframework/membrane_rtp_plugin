defmodule Membrane.RTP.VadUtils.VadParams do
  @moduledoc """
  The information about the max length of level structure is used in multiple modules
  (VAD, its utils, tests of VAD and utils...)

  It requires a few simple steps every time:
    - fetch the data from the compile file
    - multiply some numbers in this data
    - add the value to the module argument

  It's repetitive, simple and takes significant amounts of space in code.
  This module should vastly simplify this notorious task.
  """

  @default_parameters %{
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

  @params Application.compile_env(
            :membrane_rtp_plugin,
            :vad_estimation_parameters,
            @default_parameters
          )

  @immediate @params[:immediate]
  @medium @params[:medium]
  @long @params[:long]

  @spec vad_params() :: map()
  def vad_params(), do: @params

  @spec immediate() :: map()
  def immediate(), do: @immediate

  @spec medium() :: map()
  def medium(), do: @medium

  @spec long() :: map()
  def long(), do: @long

  @spec target_levels_length() :: pos_integer()
  def target_levels_length(), do: immediate()[:subunits] * medium()[:subunits] * long()[:subunits]
end
