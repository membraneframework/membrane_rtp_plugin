defmodule Membrane.RTCP.ReceiverReporter do
  @moduledoc """
  Periodically generates RTCP receive reports basing on jitter buffer stats and RTCP sender reports
  and sends them via output.
  """
  use Membrane.Source
  alias Membrane.{Buffer, RTCP}

  def_output_pad :output, mode: :push, caps: RTCP

  @impl true
  def handle_init(_options) do
    {:ok, %{}}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, caps: {:output, %RTCP{}}}, state}
  end

  @impl true
  def handle_other({:report, %RTCP.CompoundPacket{} = report}, _ctx, state) do
    buffer = %Buffer{payload: RTCP.CompoundPacket.to_binary(report)}
    {{:ok, buffer: {:output, buffer}}, state}
  end
end
