defmodule Membrane.RTCP.Forwarder do
  @moduledoc """
  Serializes and forwards `Membrane.RTCP.CompoundPacket`s via output pad.
  """
  use Membrane.Source
  alias Membrane.{Buffer, RemoteStream, RTCP}

  def_output_pad :output,
    mode: :push,
    caps: {RemoteStream, type: :packetized, content_format: RTCP}

  @impl true
  def handle_init(_options) do
    {:ok, %{}}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, caps: {:output, %RemoteStream{type: :packetized, content_format: RTCP}}}, state}
  end

  @impl true
  def handle_other({:report, %RTCP.CompoundPacket{} = report}, _ctx, state) do
    buffer = %Buffer{payload: RTCP.CompoundPacket.serialize(report)}
    {{:ok, buffer: {:output, buffer}}, state}
  end
end
