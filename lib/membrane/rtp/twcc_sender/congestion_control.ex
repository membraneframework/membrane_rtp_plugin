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
  @last_packet_interval_ms 1000

  # alpha factor for exponential moving average
  @ema_smoothing_factor 0.95

  # time required to trigger a signal, 10ms ("overuse_time_th" in RFC)
  @signal_time_threshold 10.0

  defstruct [
    # inter-group delay estimate (in ms)
    m_hat: 0.0,
    # system error covariance
    e: 0.1,
    # estimate for the state noise variance
    var_v_hat: 0.0,
    # initial value for the adaptive threshold, 12.5ms
    del_var_th: 12.5,
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
    # receiver-side bandwidth estimation, initialized as 300kbps
    a_hat: 100_000_000.0,
    # sender-side bandwidth estimation, initialized as 300kbps
    as_hat: 100_000_000.0,
    # latest estimates of receiver-side bandwidth
    r_hats: [],
    # accumulator for packet sizes that have been received through @last_packet_interval_ms
    last_packet_received_sizes: 0,
    last_packet_received_interval_start: nil,
    last_packet_received_interval_end: nil,
    debug_interarrival: []
  ]

  def update(
        %__MODULE__{m_hat: prev_m_hat} = cc,
        reference_time,
        receive_deltas,
        send_deltas,
        packet_sizes
      ) do
    receive_deltas =
      Enum.map(receive_deltas, fn delta ->
        if delta == :not_received, do: delta, else: Time.to_milliseconds(delta)
      end)

    send_deltas = Enum.map(send_deltas, &Time.to_milliseconds/1)

    cc
    |> update_metrics(receive_deltas, send_deltas)
    |> make_signal(prev_m_hat)
    |> then(fn {signal, cc} ->
      Membrane.Logger.error(inspect(signal))
      update_state(cc, signal)
    end)
    |> store_packet_received_sizes(reference_time, receive_deltas, packet_sizes)
    |> maybe_increase_bandwidth(packet_sizes)
    |> update_loss(receive_deltas)
  end

  defp update_metrics(cc, [], []), do: cc

  defp update_metrics(cc, [:not_received | recv_deltas], [send_delta | send_deltas]) do
    case {recv_deltas, send_deltas} do
      {[], []} ->
        cc

      {_recv_deltas, [next_send_delta | other_send_deltas]} ->
        update_metrics(cc, recv_deltas, [send_delta + next_send_delta | other_send_deltas])
    end
  end

  defp update_metrics(cc, [recv_delta | recv_deltas], [send_delta | send_deltas])
       when recv_delta < 0 do
    case {recv_deltas, send_deltas} do
      {[], []} ->
        cc

      {[:not_received | other_recv_deltas], [next_send_delta | other_send_deltas]} ->
        update_metrics(cc, [recv_delta | other_recv_deltas], [
          send_delta + next_send_delta | other_send_deltas
        ])

      {[next_recv_delta | other_recv_deltas], [next_send_delta | other_send_deltas]} ->
        update_metrics(cc, [recv_delta + next_recv_delta | other_recv_deltas], [
          send_delta + next_send_delta | other_send_deltas
        ])
    end
  end

  defp update_metrics(cc, [recv_delta | recv_deltas], [send_delta | send_deltas]) do
    %__MODULE__{
      m_hat: prev_m_hat,
      e: e,
      var_v_hat: var_v_hat,
      del_var_th: del_var_th,
      last_rates: last_rates
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

    cc = %__MODULE__{
      cc
      | m_hat: m_hat,
        var_v_hat: var_v_hat,
        e: e,
        last_rates: Enum.take(last_rates, 100),
        del_var_th: del_var_th
    }

    update_metrics(cc, recv_deltas, send_deltas)
  end

  defp make_signal(cc, prev_m_hat) do
    now = Time.monotonic_time()

    %__MODULE__{
      m_hat: m_hat,
      del_var_th: del_var_th,
      underuse_start_ts: underuse_start_ts,
      overuse_start_ts: overuse_start_ts
    } = cc

    cond do
      m_hat < -del_var_th ->
        underuse_start_ts = underuse_start_ts || now

        trigger_underuse? =
          Time.to_milliseconds(now - underuse_start_ts) > @signal_time_threshold and
            m_hat <= prev_m_hat

        if trigger_underuse?,
          do: {:underuse, %__MODULE__{cc | underuse_start_ts: now, overuse_start_ts: nil}},
          else:
            {:no_signal,
             %__MODULE__{cc | underuse_start_ts: underuse_start_ts, overuse_start_ts: nil}}

      m_hat > del_var_th ->
        overuse_start_ts = overuse_start_ts || now

        trigger_overuse? =
          Time.to_milliseconds(now - overuse_start_ts) > @signal_time_threshold and
            m_hat >= prev_m_hat

        if trigger_overuse?,
          do: {:overuse, %__MODULE__{cc | underuse_start_ts: nil, overuse_start_ts: now}},
          else:
            {:no_signal,
             %__MODULE__{cc | underuse_start_ts: nil, overuse_start_ts: overuse_start_ts}}

      true ->
        {:normal, %__MODULE__{cc | underuse_start_ts: nil, overuse_start_ts: nil}}
    end
  end

  # +----+--------+-----------+------------+--------+
  # |     \ State |   Hold    |  Increase  |Decrease|
  # |      \      |           |            |        |
  # | Signal\     |           |            |        |
  # +--------+----+-----------+------------+--------+
  # |  Over-use   | Decrease  |  Decrease  |        |
  # +-------------+-----------+------------+--------+
  # |  Normal     | Increase  |            |  Hold  |
  # +-------------+-----------+------------+--------+
  # |  Under-use  |           |   Hold     |  Hold  |
  # +-------------+-----------+------------+--------+

  defp update_state(cc, signal)

  defp update_state(%__MODULE__{state: :hold} = cc, :overuse),
    do: %__MODULE__{cc | state: :decrease, a_hat: @beta * cc.a_hat}

  defp update_state(%__MODULE__{state: :hold} = cc, :normal),
    do: %__MODULE__{cc | state: :increase}

  defp update_state(%__MODULE__{state: :increase} = cc, :overuse),
    do: %__MODULE__{cc | state: :decrease, a_hat: @beta * cc.a_hat}

  defp update_state(%__MODULE__{state: :increase} = cc, :underuse),
    do: %__MODULE__{cc | state: :hold}

  defp update_state(%__MODULE__{state: :decrease} = cc, :normal),
    do: %__MODULE__{cc | state: :hold}

  defp update_state(%__MODULE__{state: :decrease} = cc, :underuse),
    do: %__MODULE__{cc | state: :hold}

  defp update_state(cc, _signal), do: cc

  defp store_packet_received_sizes(cc, reference_time, receive_deltas, packet_sizes) do
    %__MODULE__{
      last_packet_received_interval_start: last_packet_received_interval_start,
      last_packet_received_interval_end: last_packet_received_interval_end,
      last_packet_received_sizes: last_packet_received_sizes
    } = cc

    {receive_deltas, packet_sizes} =
      receive_deltas
      |> Enum.zip(packet_sizes)
      |> Enum.filter(fn {delta, _size} -> delta != :not_received end)
      |> Enum.unzip()

    time_received = Enum.scan(receive_deltas, &(&1 + &2))
    latest_packet = Enum.max(time_received)
    total_size = Enum.sum(packet_sizes)

    %__MODULE__{
      cc
      | last_packet_received_interval_start:
          last_packet_received_interval_start || reference_time,
        last_packet_received_interval_end:
          (last_packet_received_interval_end || reference_time) + Time.milliseconds(latest_packet),
        last_packet_received_sizes: last_packet_received_sizes + total_size
    }
  end

  defp maybe_increase_bandwidth(%__MODULE__{state: :increase} = cc, packet_sizes) do
    %__MODULE__{
      r_hats: r_hats,
      a_hat: prev_a_hat,
      last_bandwidth_update_ts: last_bandwidth_update_ts,
      last_packet_received_interval_end: last_packet_received_interval_end,
      last_packet_received_interval_start: last_packet_received_interval_start,
      last_packet_received_sizes: last_packet_received_sizes
    } = cc

    interval =
      Time.to_milliseconds(
        last_packet_received_interval_end - last_packet_received_interval_start
      )

    if interval >= @last_packet_interval_ms do
      r_hat = 1 / (interval / 1000) * last_packet_received_sizes

      now = Time.monotonic_time()
      last_bandwidth_update_ts = last_bandwidth_update_ts || now
      time_since_last_update_ms = now - last_bandwidth_update_ts

      a_hat =
        case bitrate_mode(r_hat, cc) do
          :multiplicative ->
            eta = :math.pow(1.08, min(time_since_last_update_ms / 1000, 1))
            eta * prev_a_hat

          :additive ->
            # TODO: calculate rtt
            rtt = 30
            response_time_ms = 100 + rtt
            alpha = 0.5 * min(time_since_last_update_ms / response_time_ms, 1)
            expected_packet_size_bits = Enum.sum(packet_sizes) / length(packet_sizes)
            prev_a_hat + max(1000, alpha * expected_packet_size_bits)
        end

      a_hat = min(1.5 * r_hat, a_hat)

      %__MODULE__{
        cc
        | a_hat: a_hat,
          r_hats: Enum.take([r_hat | r_hats], 10),
          last_bandwidth_update_ts: now,
          last_packet_received_interval_end: nil,
          last_packet_received_interval_start: nil,
          last_packet_received_sizes: 0
      }
    else
      cc
    end
  end

  defp maybe_increase_bandwidth(cc, _packet_sizes), do: cc

  defp update_loss(%__MODULE__{as_hat: as_hat} = cc, receive_deltas) do
    lost = Enum.count(receive_deltas, &(&1 == :not_received))
    loss_ratio = lost / length(receive_deltas)

    as_hat =
      cond do
        loss_ratio < 0.02 -> 1.05 * as_hat
        loss_ratio > 0.1 -> as_hat * (1 - 0.5 * loss_ratio)
        true -> as_hat
      end

    # cap to 1Gbps
    as_hat = min(as_hat, 1_000_000_000)

    %__MODULE__{cc | as_hat: as_hat}
  end

  defp bitrate_mode(_r_hat, %__MODULE__{r_hats: prev_r_hats}) when length(prev_r_hats) < 2,
    do: :multiplicative

  defp bitrate_mode(r_hat, %__MODULE__{r_hats: prev_r_hats}) do
    exp_average = exponential_moving_average(@ema_smoothing_factor, prev_r_hats)
    std_dev = std_dev(prev_r_hats)

    if r_hat > exp_average + 3 * std_dev do
      :multiplicative
    else
      :additive
    end
  end

  defp exponential_moving_average(_alpha, []), do: 0

  defp exponential_moving_average(alpha, [latest_observation | older_observations]) do
    alpha * latest_observation +
      (1 - alpha) * exponential_moving_average(alpha, older_observations)
  end

  defp std_dev(observations) when observations != [] do
    n_obs = length(observations)
    mean = Enum.sum(observations) / n_obs

    observations
    |> Enum.reduce(0, fn obs, acc -> acc + (obs - mean) * (obs - mean) end)
    |> then(&(&1 / n_obs))
    |> :math.sqrt()
  end
end
