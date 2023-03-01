defmodule Membrane.RTP.OutboundRtxControllerTest do
  use ExUnit.Case, async: true

  alias Membrane.RTP.{BufferFactory, RetransmissionRequestEvent}
  alias Membrane.RTP.OutboundRtxController, as: RTX

  @base_seq_number BufferFactory.base_seq_number()
  @max_store_size RTX.max_store_size()

  test "store size is limited" do
    assert {[], state} = RTX.handle_init(%{}, %{})

    buffs = Enum.map(0..400, &BufferFactory.sample_buffer(@base_seq_number + &1))

    state =
      Enum.reduce(buffs, state, fn buffer, state ->
        assert {[forward: ^buffer], state} = RTX.handle_process(:input, buffer, %{}, state)
        state
      end)

    assert map_size(state.store) <= @max_store_size
  end

  test "retransmit stored buffer" do
    state = init()

    rtx_sn = [@base_seq_number + 98, @base_seq_number + 99]
    rtx_event = %RetransmissionRequestEvent{packet_ids: rtx_sn}
    rtx_buffers = Enum.map(rtx_sn, &BufferFactory.sample_buffer(&1))

    assert {[buffer: {:output, ^rtx_buffers}], _state} =
             RTX.handle_event(:input, rtx_event, %{}, state)
  end

  test "ignore packets not present" do
    state = init()

    rtx_event = %RetransmissionRequestEvent{
      packet_ids: [@base_seq_number + 101, @base_seq_number + 102]
    }

    assert {actions, _state} = RTX.handle_event(:input, rtx_event, %{}, state)

    bufs = for {:buffer, {:output, bufs}} <- actions, buf <- bufs, do: buf
    assert Enum.empty?(bufs)
  end

  test "ignore instant doubled RTX request" do
    state = init()

    rtx_sn = [@base_seq_number + 98, @base_seq_number + 99]
    rtx_event = %RetransmissionRequestEvent{packet_ids: rtx_sn}
    rtx_buffers = Enum.map(rtx_sn, &BufferFactory.sample_buffer(&1))

    assert {[buffer: {:output, ^rtx_buffers}], state} =
             RTX.handle_event(:input, rtx_event, %{}, state)

    assert {actions, _state} = RTX.handle_event(:input, rtx_event, %{}, state)

    bufs = for {:buffer, {:output, bufs}} <- actions, buf <- bufs, do: buf
    assert Enum.empty?(bufs)
  end

  defp init(received_bufs \\ 100) do
    {[], state} = RTX.handle_init(%{}, %{})

    buffs = Enum.map(0..received_bufs, &BufferFactory.sample_buffer(@base_seq_number + &1))

    Enum.reduce(buffs, state, fn buffer, state ->
      {[forward: ^buffer], state} = RTX.handle_process(:input, buffer, %{}, state)
      state
    end)
  end
end
