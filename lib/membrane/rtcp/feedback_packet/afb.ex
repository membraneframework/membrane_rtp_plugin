defmodule Membrane.RTCP.FeedbackPacket.AFB do
  @moduledoc """
  TODO: Mock module, for now ignores PSFB=206 & PT=15 packets.
  Should encode and decode [Application Layer Feedback](https://datatracker.ietf.org/doc/html/rfc4585#section-6.4) packets.
  """

  @behaviour Membrane.RTCP.FeedbackPacket

  defstruct []

  @impl true
  def decode(_binary) do
    # require Membrane.Logger

    # case binary do
    #   <<"REMB", num_ssrcs::8, br_exp::6, br_mantissa::18, ssrcs::binary>> ->
    #     ssrc_list = for <<ssrc::32 <- ssrcs>>, do: ssrc

    #     Membrane.Logger.warn("""
    #     REMB
    #     num_ssrcs: #{num_ssrcs}
    #     br_exp: #{br_exp}
    #     br_mantissa: #{br_mantissa}
    #     ssrcs: #{inspect(ssrc_list)}
    #     """)

    #   _ ->
    #     Membrane.Logger.warn("Received unknown App Feedback Packet")
    #     Membrane.Logger.warn(binary)
    # end

    {:ok, %__MODULE__{}}
  end

  @impl true
  def encode(_packet) do
    <<>>
  end
end
