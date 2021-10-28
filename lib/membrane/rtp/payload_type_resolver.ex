defmodule Membrane.RTP.PayloadFormatResolver do
  @moduledoc """
  Wrapper over `Membrane.RTP.PayloadFormat` that returns payloaders and depayloaders, or an error
  if they can't be resolved.
  """

  alias Membrane.RTP
  alias Membrane.RTP.PayloadFormat

  @type encoding_mapper_t :: %{RTP.encoding_name_t() => module()}

  @doc """
  Tries to resolve a depayloader based on given encoding.
  """
  @spec depayloader(RTP.encoding_name_t()) :: {:ok, module()} | :error
  def depayloader(encoding) do
    case PayloadFormat.get(encoding).depayloader do
      nil -> :error
      depayloader -> {:ok, depayloader}
    end
  end

  @doc """
  Tries to resolve a payloader based on given encoding.
  """
  @spec payloader(RTP.encoding_name_t()) :: {:ok, module()} | :error
  def payloader(encoding) do
    case PayloadFormat.get(encoding).payloader do
      nil -> :error
      payloader -> {:ok, payloader}
    end
  end
end
