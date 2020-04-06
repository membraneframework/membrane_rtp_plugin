defmodule Membrane.RTP.Packet.PayloadType do
  @moduledoc """
  This module contains utility to translate numerical payload type into an atom value.
  """

  alias Membrane.RTP

  @doc """
  Gets the name of used encoding from numerical payload according to [RFC3551](https://tools.ietf.org/html/rfc3551#page-32).
  For quick reference check [datasheet](https://www.iana.org/assignments/rtp-parameters/rtp-parameters.xhtml).
  """
  @spec get_encoding_name(payload_type :: RTP.raw_payload_type()) :: RTP.payload_type()
  def get_encoding_name(type)
  def get_encoding_name(0), do: :pcmu
  def get_encoding_name(3), do: :gsm
  def get_encoding_name(4), do: :g732
  def get_encoding_name(5), do: :dvi4
  def get_encoding_name(6), do: :dvi4
  def get_encoding_name(7), do: :lpc
  def get_encoding_name(8), do: :pcma
  def get_encoding_name(9), do: :g722
  def get_encoding_name(10), do: :l16
  def get_encoding_name(11), do: :l16
  def get_encoding_name(12), do: :qcelp
  def get_encoding_name(13), do: :cn
  def get_encoding_name(14), do: :mpa
  def get_encoding_name(15), do: :g728
  def get_encoding_name(16), do: :dvi4
  def get_encoding_name(17), do: :dvi4
  def get_encoding_name(18), do: :g729
  def get_encoding_name(25), do: :celb
  def get_encoding_name(26), do: :jpeg
  def get_encoding_name(28), do: :nv
  def get_encoding_name(31), do: :h261
  def get_encoding_name(32), do: :mpv
  def get_encoding_name(33), do: :mp2t
  def get_encoding_name(34), do: :h263

  def get_encoding_name(payload_type) when payload_type in 96..127, do: :dynamic
end
