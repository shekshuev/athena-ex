defmodule Athena.Surveys.Stats.Distributions do
  @moduledoc """
  The distribution tails the survey statistics need: normal, chi-square,
  Student's t and F.

  Implemented here rather than taken from a dependency. All four reduce to
  three classical functions - the error function, the regularized incomplete
  gamma, and the regularized incomplete beta - which is a bounded amount of
  code that can be pinned exactly against published critical values. The
  alternative was a thinly-maintained library whose F and chi-square tails are
  low-precision, and a p-value that is quietly wrong is worse than no p-value
  at all: nobody reads `0.04` and doubts it.

  The algorithms are the standard ones (Lanczos for `log_gamma`, a series and
  a Lentz continued fraction for the incomplete gamma, a Lentz continued
  fraction for the incomplete beta). The tests pin them against textbook
  critical values, so a change that breaks precision fails loudly.

  Everything here is pure and total: an undefined input returns `nil` rather
  than raising, because a degenerate group is a normal thing to find in survey
  data and should not take a dashboard down.
  """

  # Lanczos approximation, g = 7, n = 9. Accurate to about 15 significant
  # digits over the range this module uses.
  @lanczos [
    0.99999999999980993,
    676.5203681218851,
    -1_259.1392167224028,
    771.32342877765313,
    -176.61502916214059,
    12.507343278686905,
    -0.13857109526572012,
    9.9843695780195716e-6,
    1.5056327351493116e-7
  ]

  @epsilon 3.0e-12
  @tiny 1.0e-300
  @max_iterations 500

  @doc """
  Natural log of the gamma function.

  Works on the log scale throughout: `Γ(a + b)` for a contingency table of any
  size overflows a float long before the ratio it appears in does.
  """
  @spec log_gamma(number()) :: float() | nil
  def log_gamma(x) when is_number(x) and x > 0.0 do
    if x < 0.5 do
      # Reflection, so the approximation is only ever evaluated where it is
      # well conditioned.
      :math.log(:math.pi()) - :math.log(:math.sin(:math.pi() * x)) - log_gamma(1.0 - x)
    else
      z = x - 1.0

      series =
        @lanczos
        |> Enum.drop(1)
        |> Enum.with_index(1)
        |> Enum.reduce(hd(@lanczos), fn {coefficient, index}, acc ->
          acc + coefficient / (z + index)
        end)

      t = z + 7.5

      0.5 * :math.log(2.0 * :math.pi()) + (z + 0.5) * :math.log(t) - t + :math.log(series)
    end
  end

  def log_gamma(_x), do: nil

  @doc """
  The error function, via the regularized incomplete gamma: `erf(x) =
  P(1/2, x^2)` for non-negative `x`, mirrored for negative.
  """
  @spec erf(number()) :: float()
  def erf(x) when is_number(x) do
    cond do
      x == 0 -> 0.0
      x > 0 -> gamma_p(0.5, x * x)
      true -> -gamma_p(0.5, x * x)
    end
  end

  @doc """
  The regularized lower incomplete gamma `P(a, x)`.

  Uses the series below `x = a + 1` and the continued fraction above it, which
  is where each converges quickly - swapping them makes both unusably slow
  near the other's home ground.
  """
  @spec gamma_p(number(), number()) :: float() | nil
  def gamma_p(a, x) when is_number(a) and is_number(x) and a > 0 and x >= 0 do
    cond do
      x == 0 -> 0.0
      x < a + 1.0 -> gamma_series(a, x)
      true -> 1.0 - gamma_continued_fraction(a, x)
    end
  end

  def gamma_p(_a, _x), do: nil

  @doc "The regularized upper incomplete gamma `Q(a, x) = 1 - P(a, x)`."
  @spec gamma_q(number(), number()) :: float() | nil
  def gamma_q(a, x) do
    case gamma_p(a, x) do
      nil -> nil
      p -> 1.0 - p
    end
  end

  defp gamma_series(a, x) do
    prefix = -x + a * :math.log(x) - log_gamma(a)

    {sum, _term} =
      Enum.reduce_while(1..@max_iterations, {1.0 / a, 1.0 / a}, fn index, {sum, term} ->
        term = term * x / (a + index)
        sum = sum + term

        if abs(term) < abs(sum) * @epsilon do
          {:halt, {sum, term}}
        else
          {:cont, {sum, term}}
        end
      end)

    sum * :math.exp(prefix)
  end

  # Modified Lentz, as for the incomplete beta below: carrying the reciprocal
  # of `d` avoids a division by a denominator that can legitimately pass
  # through zero.
  defp gamma_continued_fraction(a, x) do
    prefix = -x + a * :math.log(x) - log_gamma(a)
    b0 = x + 1.0 - a
    c0 = 1.0 / @tiny
    d0 = 1.0 / guard_tiny(b0)

    {h, _b, _c, _d} =
      Enum.reduce_while(1..@max_iterations, {d0, b0, c0, d0}, fn index, {h, b, c, d} ->
        an = -index * (index - a)
        b = b + 2.0

        d = guard_tiny(an * d + b)
        c = guard_tiny(b + an / c)
        d = 1.0 / d
        delta = d * c
        h = h * delta

        if abs(delta - 1.0) < @epsilon do
          {:halt, {h, b, c, d}}
        else
          {:cont, {h, b, c, d}}
        end
      end)

    :math.exp(prefix) * h
  end

  @doc """
  The regularized incomplete beta `I_x(a, b)`.

  Uses the symmetry `I_x(a, b) = 1 - I_(1-x)(b, a)` to stay on the side where
  the continued fraction converges.
  """
  @spec beta_inc(number(), number(), number()) :: float() | nil
  def beta_inc(a, b, x)
      when is_number(a) and is_number(b) and is_number(x) and a > 0 and b > 0 do
    cond do
      x <= 0.0 ->
        0.0

      x >= 1.0 ->
        1.0

      true ->
        front =
          :math.exp(
            log_gamma(a + b) - log_gamma(a) - log_gamma(b) + a * :math.log(x) +
              b * :math.log(1.0 - x)
          )

        if x < (a + 1.0) / (a + b + 2.0) do
          front * beta_continued_fraction(a, b, x) / a
        else
          1.0 - front * beta_continued_fraction(b, a, 1.0 - x) / b
        end
    end
  end

  def beta_inc(_a, _b, _x), do: nil

  defp beta_continued_fraction(a, b, x) do
    qab = a + b
    qap = a + 1.0
    qam = a - 1.0

    c0 = 1.0
    d0 = 1.0 / guard_tiny(1.0 - qab * x / qap)

    {h, _c, _d} =
      Enum.reduce_while(1..@max_iterations, {d0, c0, d0}, fn m, {h, c, d} ->
        m2 = 2 * m

        # Even step.
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = guard_tiny(1.0 + aa * d)
        c = guard_tiny(1.0 + aa / c)
        d = 1.0 / d
        h = h * d * c

        # Odd step.
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = guard_tiny(1.0 + aa * d)
        c = guard_tiny(1.0 + aa / c)
        d = 1.0 / d
        delta = d * c
        h = h * delta

        if abs(delta - 1.0) < @epsilon do
          {:halt, {h, c, d}}
        else
          {:cont, {h, c, d}}
        end
      end)

    h
  end

  defp guard_tiny(value) when abs(value) < @tiny, do: @tiny
  defp guard_tiny(value), do: value

  # -- the tails the tests actually ask for ---------------------------------

  @doc "The standard normal CDF, `P(Z <= z)`."
  @spec normal_cdf(number()) :: float()
  def normal_cdf(z) when is_number(z), do: 0.5 * (1.0 + erf(z / :math.sqrt(2.0)))

  @doc """
  Two-tailed p-value for a standard normal statistic - what the Mann-Whitney
  and Kruskal-Wallis normal approximations report.
  """
  @spec normal_two_tailed(number()) :: float()
  def normal_two_tailed(z) when is_number(z), do: 2.0 * (1.0 - normal_cdf(abs(z)))

  @doc """
  Upper-tail p-value for a chi-square statistic. Chi-square tests are
  one-tailed by construction: only a large statistic is evidence against
  independence.
  """
  @spec chi_square_p(number(), number()) :: float() | nil
  def chi_square_p(chi_square, df)
      when is_number(chi_square) and is_number(df) and chi_square >= 0 and df > 0 do
    gamma_q(df / 2.0, chi_square / 2.0)
  end

  def chi_square_p(_chi_square, _df), do: nil

  @doc """
  Two-tailed p-value for a t statistic.

  Two-tailed because a survey comparison is almost never directional in
  advance: "did these two groups answer differently" is the question, not
  "did this group answer higher".
  """
  @spec t_p(number(), number()) :: float() | nil
  def t_p(t, df) when is_number(t) and is_number(df) and df > 0 do
    beta_inc(df / 2.0, 0.5, df / (df + t * t))
  end

  def t_p(_t, _df), do: nil

  @doc "Upper-tail p-value for an F statistic, as ANOVA reports it."
  @spec f_p(number(), number(), number()) :: float() | nil
  def f_p(f, df1, df2)
      when is_number(f) and is_number(df1) and is_number(df2) and f >= 0 and df1 > 0 and df2 > 0 do
    beta_inc(df2 / 2.0, df1 / 2.0, df2 / (df2 + df1 * f))
  end

  def f_p(_f, _df1, _df2), do: nil
end
