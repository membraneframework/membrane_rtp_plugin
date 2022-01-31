defmodule Membrane.RTP.TWCCSender.CongestionControl do
  @moduledoc """
  The module implements [Google congestion control algorithm](https://datatracker.ietf.org/doc/html/draft-ietf-rmcat-gcc-02).
  """
  alias Membrane.Time

  require Membrane.Logger

  # state noise covariance
  @q 0.001
  # filter coefficient for the measured noise variance, between [0.1, 0.001]
  @chi 0.01

  # decrease rate factor
  @beta 0.85

  # coefficients for the adaptive threshold
  @coeff_K_u 0.01
  @coeff_K_d 0.00018

  # T: Time window for measuring the received bitrate (in ms), between [0.5, 1] s
  @last_packet_interval 1000

  # alpha factor for exponential moving average
  @ema_alpha_factor 0.95

  defstruct [
    # inter-group mean delay estimate (in ms)
    m_hat: 0,
    # system error covariance
    e: 0.1,
    # estimate for the state noise variance
    var_v_hat: 0,
    # initial value for the adaptive threshold, 12.5ms
    del_var_th: 12.5,
    # time required to trigger a signal, 10ms
    signal_time_th: 10,
    # last rates at which packets were received
    last_rates: [],
    # current delay-based controller state
    state: :increase,
    # timestamp indicating when we started to overusing the link
    overuse_start_ts: nil,
    # timestamp indicating when we started to underusing the link
    underuse_start_ts: nil,
    # latest timestamp indicating when the receiver-side bandwidth was updated
    last_bandwidth_update_ts: nil,
    # receiver-side bandwidth estimation
    a_hat: 0,
    # sender-side bandwidth estimation
    as_hat: 0,
    # latest estimates of receiver-side bandwidth
    r_hats: [],
    debug_interarrival: []
  ]

  def update(cc, receive_deltas, send_deltas, packet_sizes) do
    receive_deltas =
      Enum.map(receive_deltas, fn delta ->
        if delta == :not_received, do: delta, else: Time.to_milliseconds(delta)
      end)

    send_deltas = Enum.map(send_deltas, &Time.to_milliseconds/1)

    Enum.zip_reduce(receive_deltas, send_deltas, cc, fn recv_delta, send_delta, cc ->
      do_update(cc, recv_delta, send_delta)
    end)
    |> update_bandwidth(receive_deltas, packet_sizes)
    |> update_loss(receive_deltas)
    |> tap(
      &Membrane.Logger.error(
        "avg_interarrival: " <>
          inspect(Enum.sum(&1.debug_interarrival) / length(&1.debug_interarrival))
      )
    )
  end

  defp update_loss(%__MODULE__{as_hat: as_hat} = cc, receive_deltas) do
    loss = Enum.count(receive_deltas, &(&1 == :not_received))
    loss_ratio = loss / length(receive_deltas)

    as_hat =
      cond do
        loss_ratio < 0.02 -> 1.05 * as_hat
        loss_ratio > 0.1 -> as_hat * (1 - 0.5 * loss_ratio)
        true -> as_hat
      end

    %__MODULE__{as_hat: as_hat}
  end

  defp do_update(%__MODULE__{m_hat: prev_m_hat} = cc, recv_delta, send_delta) do
    cc
    |> update_metrics(recv_delta, send_delta)
    |> make_signal(prev_m_hat)
    |> then(fn {signal, cc} -> update_state(cc, signal) end)
  end

  defp update_bandwidth(cc, receive_deltas, packet_sizes) do
    %__MODULE__{
      r_hats: r_hats,
      a_hat: prev_a_hat,
      last_bandwidth_update_ts: last_bandwidth_update_ts
    } = cc

    total_size =
      Enum.reverse(receive_deltas)
      |> Enum.zip(Enum.reverse(packet_sizes))
      |> Enum.reduce_while({0, 0}, fn {recv_delta, packet_size}, {time, total_size} ->
        cond do
          recv_delta == :not_received or recv_delta < 0 ->
            {:cont, {time, total_size}}

          recv_delta + time <= @last_packet_interval ->
            {:cont, {time + recv_delta, total_size + packet_size}}

          true ->
            {:halt, {time, total_size}}
        end
      end)
      |> then(&elem(&1, 1))

    r_hat = 1 / @last_packet_interval * total_size

    now = Time.monotonic_time()
    last_bandwidth_update_ts = last_bandwidth_update_ts || now

    bandwidth_update_delta =
      Time.to_milliseconds(Time.monotonic_time() - last_bandwidth_update_ts)

    a_hat =
      case bitrate_mode(r_hat, cc) do
        :multiplicative ->
          eta = :math.pow(1.08, min(bandwidth_update_delta, 1))
          eta * prev_a_hat

        :additive ->
          # rtt
          response_time_ms = 100 + 30
          alpha = 0.5 * min(bandwidth_update_delta / response_time_ms, 1)
          bits_per_frame = prev_a_hat / 30
          packets_per_frame = ceil(bits_per_frame / (1200 * 8))
          expected_packet_size_bits = bits_per_frame / packets_per_frame
          prev_a_hat + max(1000, alpha * expected_packet_size_bits)
      end

    a_hat = if a_hat < 1.5 * r_hat, do: @beta * r_hat, else: a_hat

    %__MODULE__{
      cc
      | a_hat: a_hat,
        r_hats: [r_hat | r_hats]
    }
  end

  defp exponential_moving_average(_alpha, []), do: 0

  defp exponential_moving_average(alpha, [latest_observation | older_observations]) do
    alpha * latest_observation +
      (1 - alpha) * exponential_moving_average(alpha, older_observations)
  end

  defp std_dev(observations) do
    mean = Enum.sum(observations) / length(observations)

    observations
    |> Enum.map(fn obs -> (obs - mean) * (obs - mean) end)
    |> then(&(&1 / length(observations)))
    |> :math.sqrt()
  end

  defp bitrate_mode(r_hat, cc) do
    exp_average = exponential_moving_average(@ema_alpha_factor, cc.r_hats)
    std_dev = std_dev(cc.r_hats)

    if r_hat > exp_average + 3 * std_dev do
      :multiplicative
    else
      :additive
    end
  end

  defp update_metrics(cc, :not_received, _send_delta), do: cc

  defp update_metrics(cc, recv_delta, _send_delta) when recv_delta < 0, do: cc

  defp update_metrics(cc, recv_delta, send_delta) do
    %__MODULE__{
      m_hat: prev_m_hat,
      e: e,
      var_v_hat: var_v_hat,
      del_var_th: del_var_th,
      last_rates: last_rates,
      debug_interarrival: debug_interarrival
    } = cc

    interpacket_delta = recv_delta - send_delta

    z = interpacket_delta - prev_m_hat

    last_rates = if recv_delta != 0, do: [1 / recv_delta | last_rates], else: last_rates

    f_max = Enum.max(last_rates, fn -> 0.5 end)

    alpha = :math.pow(1 - @chi, 30 / (1000 * f_max))

    var_v_hat = max(alpha * var_v_hat + (1 - alpha) * z * z, 1)

    k = (e + @q) / (var_v_hat + e + @q)

    e = (1 - k) * (e + @q)

    coeff = min(z, 3 * :math.sqrt(var_v_hat))

    m_hat = prev_m_hat + coeff * k
    abs_m_hat = abs(m_hat)

    del_var_th =
      if abs_m_hat - del_var_th <= 15 do
        coeff_K = if abs_m_hat < del_var_th, do: @coeff_K_d, else: @coeff_K_u
        gain = recv_delta * coeff_K * (abs_m_hat - del_var_th)
        max(min(del_var_th + gain, 600), 6)
      else
        del_var_th
      end

    %__MODULE__{
      cc
      | m_hat: m_hat,
        var_v_hat: var_v_hat,
        e: e,
        last_rates: Enum.take(last_rates, 10),
        del_var_th: del_var_th,
        debug_interarrival: Enum.take([interpacket_delta | debug_interarrival], 1000)
    }
  end

  defp make_signal(cc, prev_m_hat) do
    now = Time.monotonic_time()
    underuse_start_ts = cc.underuse_start_ts || now
    overuse_start_ts = cc.overuse_start_ts || now

    trigger_underuse? =
      Time.to_milliseconds(now - underuse_start_ts) > cc.signal_time_th and cc.m_hat <= prev_m_hat

    trigger_overuse? =
      Time.to_milliseconds(now - overuse_start_ts) > cc.signal_time_th and cc.m_hat >= prev_m_hat

    cond do
      cc.m_hat < -cc.del_var_th and trigger_underuse? ->
        {:underuse, %__MODULE__{cc | underuse_start_ts: now, overuse_start_ts: nil}}

      cc.m_hat < -cc.del_var_th ->
        {:normal, %__MODULE__{cc | underuse_start_ts: underuse_start_ts, overuse_start_ts: nil}}

      cc.m_hat > cc.del_var_th and trigger_overuse? ->
        {:overuse, %__MODULE__{cc | overuse_start_ts: now, underuse_start_ts: nil}}

      cc.m_hat > cc.del_var_th ->
        {:normal, %__MODULE__{cc | overuse_start_ts: overuse_start_ts, underuse_start_ts: nil}}

      true ->
        {:normal, %__MODULE__{cc | overuse_start_ts: nil, underuse_start_ts: nil}}
    end
  end

  defp update_state(cc, signal)

  defp update_state(%__MODULE__{state: :hold} = cc, :overuse),
    do: %__MODULE__{cc | state: :decrease}

  defp update_state(%__MODULE__{state: :hold} = cc, :normal),
    do: %__MODULE__{cc | state: :increase}

  defp update_state(%__MODULE__{state: :increase} = cc, :overuse),
    do: %__MODULE__{cc | state: :decrease}

  defp update_state(%__MODULE__{state: :increase} = cc, :underuse),
    do: %__MODULE__{cc | state: :hold}

  defp update_state(%__MODULE__{state: :decrease} = cc, :normal),
    do: %__MODULE__{cc | state: :hold}

  defp update_state(%__MODULE__{state: :decrease} = cc, :underuse),
    do: %__MODULE__{cc | state: :hold}

  defp update_state(cc, _signal), do: cc
end
