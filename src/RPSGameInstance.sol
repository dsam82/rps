// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "@openzeppelin/contracts/interfaces/IERC20.sol";

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract RPSGameInstance is Initializable {
    /// --------------------------------------------------------------
    /// Structs
    /// --------------------------------------------------------------

    enum GameState {
        GameCreated,
        WaitingForPlayersToBet,
        WaitingForPlayersToSubmitMove,
        WaitingForPlayersToReveal,
        Finished,
        Withdrawn
    }

    enum PlayerState {
        Initialized,
        Betted,
        SubmittedMove,
        Revealed,
        RematchRequested
    }

    struct PlayerGameData {
        PlayerState playerState;
        bytes32 move;
    }

    struct Game {
        GameState state;
        address playerA;
        address playerB;
        address winner;
        uint256 betAmount;
        PlayerGameData[2] playerGameData;
    }

    /// ---------------------------------------------------------------
    /// events
    /// ---------------------------------------------------------------

    event GameInstanceInitialized(address indexed owner);
    event GameCreated(uint256 indexed gameId, address indexed playerA, address indexed playerB, uint256 betAmount);
    event GameStarted(uint256 indexed gameId, address indexed playerA, address indexed playerB);
    event MoveSubmitted(address indexed player, uint256 indexed gameId, bytes32 move);
    event MoveRevealed(address indexed player, uint256 indexed gameId, uint8 move);
    event GameFinished(uint256 indexed gameId, address indexed playerA, address indexed playerB, address winner);
    event FundsWithdrawn(address indexed player, uint256 indexed gameId, uint256 winnings);

    /// ---------------------------------------------------------------
    /// constants
    /// ---------------------------------------------------------------

    bytes32 public constant ROCK = keccak256(abi.encodePacked(uint8(1))); // ROCK
    bytes32 public constant PAPER = keccak256(abi.encodePacked(uint8(2))); // PAPER
    bytes32 public constant SCISSORS = keccak256(abi.encodePacked(uint8(3))); // SCISSORS
    uint256 private constant INCENTIVE_DURATION = 1 hours;

    /// ---------------------------------------------------------------
    /// storage variables
    /// ---------------------------------------------------------------

    uint256 public incentiveStartTime;
    address public owner;
    Game[] public games;
    mapping(address => uint256) private gamesMapping;
    IERC20 public token;

    /// ---------------------------------------------------------------
    /// modifiers
    /// ---------------------------------------------------------------

    modifier isValidGamePlayer(uint256 _gameId, address _player) {
        require(_player == games[_gameId].playerA || _player == games[_gameId].playerB, "Player is not a valid player");
        _;
    }

    modifier isValidGame(uint256 _gameId) {
        require(_gameId < games.length, "Game does not exist");
        _;
    }

    modifier canIncentivizeOpponent(uint256 _gameId) {
        uint8 playerIndex = owner == msg.sender ? 0 : 1;
        uint8 opponentIndex = playerIndex ^ 1;

        if (games[_gameId].state == GameState.WaitingForPlayersToSubmitMove) {
            require(
                games[_gameId].playerGameData[playerIndex].playerState == PlayerState.SubmittedMove &&
                    games[_gameId].playerGameData[opponentIndex].playerState != PlayerState.SubmittedMove,
                "Cannot incentivize opponent"
            );
        }
        if (games[_gameId].state == GameState.WaitingForPlayersToReveal) {
            require(
                games[_gameId].playerGameData[playerIndex].playerState == PlayerState.Revealed &&
                    games[_gameId].playerGameData[opponentIndex].playerState != PlayerState.Revealed,
                "Cannot incentivize opponent"
            );
        }
        _;
    }

    /// ---------------------------------------------------------------
    /// initializer
    /// ---------------------------------------------------------------

    function initialize(address _player, address tokenAddress) external initializer returns (bool) {
        owner = _player;
        token = IERC20(tokenAddress);

        // Push a dummy game
        Game storage _game = games.push();
        _game.playerA = address(0);
        _game.playerB = address(0);
        _game.betAmount = 0;
        _game.state = GameState.Finished;

        emit GameInstanceInitialized(owner);
        return true;
    }

    /// ---------------------------------------------------------------
    /// game functions
    /// ---------------------------------------------------------------

    /// @notice starts a new game
    /// @dev creates a new game for new opponent and reuses previous game if exists
    /// @param _player opponent address other than the owner
    /// @param _betAmount amount of tokens to bet
    /// @return gameId id of the created game
    function createGame(address _player, uint256 _betAmount) external returns (uint256) {
        require(_player != owner, "PlayerA and PlayerB different");
        require(_player != address(0), "PlayerA or PlayerB null");

        uint256 gameId = getGameId(_player);
        if (gameId == 0) {
            gameId == games.length;

            Game storage _game = games.push();
            _game.playerA = owner;
            _game.playerB = _player;
            _game.betAmount = _betAmount;
            _game.state = GameState.GameCreated;

            gamesMapping[_player] = gameId;
        } else {
            require(games[gameId].state == GameState.Withdrawn, "players not withdrawn");

            games[gameId].betAmount = _betAmount;
            games[gameId].state = GameState.GameCreated;
            games[gameId].playerGameData[0].playerState = PlayerState.Initialized;
            games[gameId].playerGameData[1].playerState = PlayerState.Initialized;
        }

        emit GameCreated(gameId, owner, _player, _betAmount);

        return gameId;
    }

    /// @notice register a player's bet
    /// @dev change game state to WaitingForPlayersToSubmitMove
    function register(uint256 _gameId)
        external
        isValidGame(_gameId)
        isValidGamePlayer(_gameId, msg.sender)
        returns (bool)
    {
        require(
            games[_gameId].state == GameState.GameCreated || games[_gameId].state == GameState.WaitingForPlayersToBet,
            "Game not created yet"
        );

        uint8 playerIndex = msg.sender == owner ? 0 : 1;

        require(
            games[_gameId].playerGameData[playerIndex].playerState != PlayerState.Betted,
            "Player already deposited"
        );
        require(token.balanceOf(msg.sender) >= games[_gameId].betAmount, "Not enough tokens");
        require(token.allowance(msg.sender, address(this)) == games[_gameId].betAmount, "Not enough allowance");

        bool success = token.transferFrom(msg.sender, address(this), games[_gameId].betAmount);

        if (success) {
            games[_gameId].playerGameData[playerIndex].playerState = PlayerState.Betted;

            if (
                games[_gameId].playerGameData[0].playerState == PlayerState.Betted &&
                games[_gameId].playerGameData[1].playerState == PlayerState.Betted
            ) {
                games[_gameId].state = GameState.WaitingForPlayersToSubmitMove;

                emit GameStarted(_gameId, games[_gameId].playerA, games[_gameId].playerB);
            } else {
                games[_gameId].state = GameState.WaitingForPlayersToBet;
            }
        }

        return success;
    }

    /// @notice players can submit a move packed with a password
    /// @dev changes game state to move reveal
    function submitMove(uint256 _gameId, bytes32 _moveHash)
        external
        isValidGame(_gameId)
        isValidGamePlayer(_gameId, msg.sender)
    {
        uint8 playerIndex = msg.sender == owner ? 0 : 1;

        require(games[_gameId].state == GameState.WaitingForPlayersToSubmitMove, "Betting not done");
        require(
            games[_gameId].playerGameData[playerIndex].playerState != PlayerState.SubmittedMove,
            "Move already submitted"
        );
        require(_moveHash != bytes32(0), "MoveHash null");

        require(incentiveStartTime == 0 || block.timestamp < incentiveStartTime, "You are late");

        games[_gameId].playerGameData[playerIndex].move = _moveHash;
        games[_gameId].playerGameData[playerIndex].playerState = PlayerState.SubmittedMove;

        if (
            games[_gameId].playerGameData[0].playerState == PlayerState.SubmittedMove &&
            games[_gameId].playerGameData[1].playerState == PlayerState.SubmittedMove
        ) {
            games[_gameId].state = GameState.WaitingForPlayersToReveal;
        }

        emit MoveSubmitted(msg.sender, _gameId, _moveHash);
    }

    /// @notice checks if the hash move is valid and stores revealed move
    /// @dev changes player state to revealed and emits MoveRevealed and computes result if both player moves revealed
    /// @param _gameId game id
    /// @param _move original move (Rock, Paper, Scissors)
    /// @param _salt password used with the hashedMove
    function revealMove(
        uint256 _gameId,
        uint8 _move,
        bytes32 _salt
    ) external isValidGame(_gameId) isValidGamePlayer(_gameId, msg.sender) {
        require(games[_gameId].state == GameState.WaitingForPlayersToReveal, "Move submissions not done");

        uint8 playerIndex = msg.sender == owner ? 0 : 1;

        require(
            games[_gameId].playerGameData[playerIndex].playerState != PlayerState.Revealed,
            "Player already revealed"
        );
        require(incentiveStartTime == 0 || block.timestamp < incentiveStartTime, "You are late");

        bytes32 _moveHash = keccak256(abi.encodePacked(_move, _salt));
        require(_moveHash == games[_gameId].playerGameData[playerIndex].move, "MoveHash invalid");

        if (_move > 3) {
            delete games[_gameId].playerGameData[playerIndex].move;
            games[_gameId].state = GameState.WaitingForPlayersToSubmitMove;
            games[_gameId].playerGameData[playerIndex].playerState = PlayerState.Betted;
        }

        games[_gameId].playerGameData[playerIndex].move = keccak256(abi.encodePacked(_move));
        games[_gameId].playerGameData[playerIndex].playerState = PlayerState.Revealed;

        emit MoveRevealed(msg.sender, _gameId, _move);

        if (
            games[_gameId].playerGameData[0].playerState == PlayerState.Revealed &&
            games[_gameId].playerGameData[1].playerState == PlayerState.Revealed
        ) {
            getGameResult(_gameId);
        }
    }

    /// @notice computes game result and emits GameFinished event
    /// @dev changes game state to finished after which players can either choose to withdraw or rematch
    function getGameResult(uint256 _gameId) private {
        bytes32 playerAMove = games[_gameId].playerGameData[0].move;
        bytes32 playerBMove = games[_gameId].playerGameData[1].move;

        if (playerAMove == playerBMove) {
            games[_gameId].winner = address(0);
        } else if (playerAMove == ROCK) {
            games[_gameId].winner = games[_gameId].playerGameData[1].move == PAPER
                ? games[_gameId].playerB
                : games[_gameId].playerA;
        } else if (playerAMove == PAPER) {
            games[_gameId].winner = games[_gameId].playerGameData[1].move == SCISSORS
                ? games[_gameId].playerB
                : games[_gameId].playerA;
        } else {
            games[_gameId].winner = games[_gameId].playerGameData[1].move == ROCK
                ? games[_gameId].playerB
                : games[_gameId].playerA;
        }

        games[_gameId].state = GameState.Finished;

        emit GameFinished(_gameId, games[_gameId].playerA, games[_gameId].playerB, games[_gameId].winner);
    }

    function incentivizePlayer(uint256 _gameId) external isValidGame(_gameId) canIncentivizeOpponent(_gameId) {
        if (incentiveStartTime == 0) {
            incentiveStartTime = block.timestamp + INCENTIVE_DURATION;
        }

        if (incentiveStartTime != 0 && block.timestamp > incentiveStartTime) {
            games[_gameId].state = GameState.Finished;
            games[_gameId].winner = msg.sender;
            emit GameFinished(_gameId, games[_gameId].playerA, games[_gameId].playerB, msg.sender);
        }
    }

    /// @notice player can request for rematch after match has ended
    /// @dev if both player confirm, game state changes to Rematch
    /// Either player can reject this by withdrawing the amount
    /// Bet amount will be same if both players agree for rematch
    function requestRematch(uint256 _gameId) external isValidGame(_gameId) isValidGamePlayer(_gameId, msg.sender) {
        require(games[_gameId].state == GameState.Finished, "Game not finished");

        uint8 playerIndex = msg.sender == owner ? 0 : 1;

        if (games[_gameId].winner == address(0)) {
            games[_gameId].playerGameData[playerIndex].playerState = PlayerState.Betted;

            if (
                games[_gameId].playerGameData[0].playerState == PlayerState.Betted &&
                games[_gameId].playerGameData[1].playerState == PlayerState.Betted
            ) {
                games[_gameId].state = GameState.WaitingForPlayersToSubmitMove;
                return;
            }
        } else if (games[_gameId].winner == msg.sender) {
            games[_gameId].playerGameData[playerIndex].playerState = PlayerState.Betted;
            token.transfer(msg.sender, games[_gameId].betAmount);
        } else {
            games[_gameId].playerGameData[playerIndex].playerState = PlayerState.RematchRequested;
        }

        uint8 winnerIndex = games[_gameId].winner == owner ? 0 : 1;
        uint8 loserIndex = winnerIndex == 0 ? 1 : 0;

        if (
            games[_gameId].playerGameData[winnerIndex].playerState == PlayerState.Betted &&
            games[_gameId].playerGameData[loserIndex].playerState == PlayerState.RematchRequested
        ) {
            games[_gameId].state = GameState.WaitingForPlayersToBet;
        }
    }

    /// @notice winner can start a new game with bet amount as his winnings
    function rematchWithWinnings(uint256 _gameId) external isValidGame(_gameId) {
        require(msg.sender == games[_gameId].winner, "only winner can proceed.");
        require(games[_gameId].state == GameState.Finished, "game not finished yet");

        uint8 playerIndex = msg.sender == owner ? 0 : 1;

        games[_gameId].state = GameState.WaitingForPlayersToBet;
        games[_gameId].betAmount = 2 * games[_gameId].betAmount;
        games[_gameId].winner = address(0);
        games[_gameId].playerGameData[playerIndex].playerState = PlayerState.Betted;
    }

    /// @notice withdraw winnings after the game ended
    /// @dev either player can withdraw bet amount to both players after game has finished
    function withdrawWinnings(uint256 _gameId) external isValidGame(_gameId) isValidGamePlayer(_gameId, msg.sender) {
        require(games[_gameId].state == GameState.Finished, "Game not finished yet");
        if (games[_gameId].betAmount == 0) {
            games[_gameId].state = GameState.Withdrawn;
            return;
        }

        uint8 playerIndex = msg.sender == owner ? 0 : 1;

        require(games[_gameId].state != GameState.Withdrawn, "Already withdrawn");
        require(
            games[_gameId].playerGameData[playerIndex].playerState != PlayerState.RematchRequested,
            "rematch requested"
        );

        games[_gameId].state = GameState.Withdrawn;

        if (games[_gameId].winner != address(0)) {
            require(games[_gameId].winner == msg.sender, "Oops, winners only");
            token.transfer(msg.sender, 2 * games[_gameId].betAmount);
            emit FundsWithdrawn(msg.sender, _gameId, 2 * games[_gameId].betAmount);
        } else {
            token.transfer(games[_gameId].playerA, games[_gameId].betAmount);
            emit FundsWithdrawn(games[_gameId].playerA, _gameId, games[_gameId].betAmount);

            token.transfer(games[_gameId].playerB, games[_gameId].betAmount);
            emit FundsWithdrawn(games[_gameId].playerB, _gameId, games[_gameId].betAmount);
        }
    }

    /// @notice withdraw bet amount before game starts
    /// @dev withdraws both players amount and changes game state to Withdrawn
    function withdrawBeforeGameStarts(uint256 _gameId)
        external
        isValidGame(_gameId)
        isValidGamePlayer(_gameId, msg.sender)
    {
        require(
            games[_gameId].state == GameState.GameCreated ||
                games[_gameId].state == GameState.WaitingForPlayersToBet ||
                games[_gameId].state == GameState.WaitingForPlayersToSubmitMove,
            "game not in required phase"
        );
        if (games[_gameId].betAmount == 0) {
            games[_gameId].state = GameState.Withdrawn;
            return;
        }

        games[_gameId].state = GameState.Withdrawn;

        if (games[_gameId].playerGameData[0].playerState == PlayerState.Betted) {
            token.transfer(games[_gameId].playerA, games[_gameId].betAmount);
            emit FundsWithdrawn(games[_gameId].playerA, _gameId, games[_gameId].betAmount);
        }
        if (games[_gameId].playerGameData[1].playerState == PlayerState.Betted) {
            token.transfer(games[_gameId].playerB, games[_gameId].betAmount);
            emit FundsWithdrawn(games[_gameId].playerB, _gameId, games[_gameId].betAmount);
        }
    }

    /// ---------------------------------------------------------------
    /// Public getters
    /// ---------------------------------------------------------------

    function getGameId(address _player) public view returns (uint256) {
        return gamesMapping[_player];
    }

    function getGameBetAmount(uint256 _gameId) public view isValidGame(_gameId) returns (uint256) {
        return games[_gameId].betAmount;
    }

    function getGamePlayers(uint256 _gameId) public view isValidGame(_gameId) returns (address, address) {
        return (games[_gameId].playerA, games[_gameId].playerB);
    }

    function getGame(uint256 _gameId) public view isValidGame(_gameId) returns (bytes memory) {
        return
            abi.encode(
                games[_gameId].playerA,
                games[_gameId].playerB,
                games[_gameId].winner,
                games[_gameId].betAmount,
                games[_gameId].state
            );
    }
}
