defmodule Codebattle.Tournament.Individual do
  alias Codebattle.Repo
  alias Codebattle.Tournament

  use Tournament.Base

  @impl Tournament.Base
  def join(%{state: "upcoming"} = tournament, %{user: user}) do
    add_intended_player_id(tournament, user.id)
  end

  @impl Tournament.Base
  def join(%{state: "waiting_participants"} = tournament, %{user: user}) do
    player = Map.put(user, :lang, user.lang || tournament.default_language)
    add_player(tournament, player)
  end

  @impl Tournament.Base
  def join(tournament, _user), do: tournament

  @impl Tournament.Base
  def complete_players(tournament) do
    bots_count =
      if tournament.players_count do
        tournament.players_count - players_count(tournament)
      else
        if players_count(tournament) > 1 do
          power =
            tournament
            |> players_count()
            |> :math.log2()
            |> ceil()

          round(:math.pow(2, power)) - players_count(tournament)
        else
          1
        end
      end

    new_players =
      tournament
      |> get_players
      |> Enum.concat(Codebattle.Bot.Builder.build_list(bots_count))

    tournament
    |> Tournament.changeset(%{
      data: DeepMerge.deep_merge(tournament.data, %{players: new_players}),
      players_count: Enum.count(new_players)
    })
    |> Repo.update!()
  end

  @impl Tournament.Base
  def build_matches(%{step: 0} = tournament) do
    players = tournament |> get_players |> Enum.shuffle()

    matches = pair_players_to_matches(players, tournament.step)

    tournament
    |> Tournament.changeset(%{
      data: DeepMerge.deep_merge(Map.from_struct(tournament.data), %{matches: matches})
    })
    |> Repo.update!()
  end

  @impl Tournament.Base
  def build_matches(tournament) do
    if final_step?(tournament) do
      tournament
    else
      matches = tournament |> get_matches |> Enum.map(&Map.from_struct/1)

      winners =
        matches
        |> Enum.filter(fn match -> match.round_id == tournament.step - 1 end)
        |> Enum.map(fn match -> pick_winner(match) end)

      new_matches = matches ++ pair_players_to_matches(winners, tournament.step)

      tournament
      |> Tournament.changeset(%{
        data: DeepMerge.deep_merge(Map.from_struct(tournament.data), %{matches: new_matches})
      })
      |> Repo.update!()
    end
  end

  @impl Tournament.Base
  def maybe_finish(tournament) do
    if final_step?(tournament) do
      new_tournament =
        tournament
        |> Tournament.changeset(%{state: "finished"})
        |> Repo.update!()

      # Tournament.GlobalSupervisor.terminate_tournament(tournament.id)
      new_tournament
    else
      tournament
    end
  end

  defp pair_players_to_matches(players, step) do
    Enum.reduce(players, [%{}], fn player, acc ->
      player = Map.merge(player, %{game_result: "waiting"})

      case List.first(acc) do
        map when map == %{} ->
          [_h | t] = acc
          [%{state: "waiting", round_id: step, players: [player]} | t]

        match ->
          case(Enum.count(match.players)) do
            1 ->
              [_h | t] = acc
              [DeepMerge.deep_merge(match, %{players: match.players ++ [player]}) | t]

            _ ->
              [%{state: "waiting", round_id: step, players: [player]} | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp final_step?(tournament) do
    tournament.players_count == :math.pow(2, tournament.step)
  end
end
