require 'socket'
require 'websocket'
require 'json'

BLOCK_SIZE = 20
WIDTH = 600
HEIGHT = 600

PLAYER_COLORS = ['green', 'blue', 'orange', 'red']

START_POSITIONS = [
  { x: 100, y: 100, direction: 'right' },
  { x: 500, y: 500, direction: 'left' },
  { x: 100, y: 500, direction: 'right' },
  { x: 500, y: 100, direction: 'left' }
]

def create_snake(x, y, direction)
  body = []
  5.times do |i|
    body << { x: x - (i * BLOCK_SIZE), y: y }
  end
  {
    body: body,
    direction: direction,
    alive: true,
    score: 0,
    slow_timer: 0,
    moves: 0,
    skip: false
  }
end

def create_food(golden: false)
  {
    x: rand(0..29) * BLOCK_SIZE,
    y: rand(0..29) * BLOCK_SIZE,
    golden: golden  # true se for comida dourada
  }
end

# bola maluca que anda sozinha pelo mapa
def create_crazy_ball
  {
    x: rand(0..29) * BLOCK_SIZE,
    y: rand(0..29) * BLOCK_SIZE,
    direction: ['right', 'left', 'up', 'down'].sample,  # direção aleatória
    active: true
  }
end

def move_snake(snake)
  return if !snake[:alive]
  if snake[:slow_timer] > 0
    snake[:slow_timer] -= 1
    snake[:skip] = !snake[:skip]
    return if snake[:skip]
  end
  head = snake[:body].first
  new_head = case snake[:direction]
             when 'right' then { x: head[:x] + BLOCK_SIZE, y: head[:y] }
             when 'left'  then { x: head[:x] - BLOCK_SIZE, y: head[:y] }
             when 'up'    then { x: head[:x], y: head[:y] - BLOCK_SIZE }
             when 'down'  then { x: head[:x], y: head[:y] + BLOCK_SIZE }
             end
  snake[:body].unshift(new_head)
  snake[:body].pop
  snake[:moves] += 1
end

def move_crazy_ball(ball)
  # muda de direção aleatoriamente às vezes
  ball[:direction] = ['right', 'left', 'up', 'down'].sample if rand(10) < 2

  case ball[:direction]
  when 'right' then ball[:x] += BLOCK_SIZE
  when 'left'  then ball[:x] -= BLOCK_SIZE
  when 'up'    then ball[:y] -= BLOCK_SIZE
  when 'down'  then ball[:y] += BLOCK_SIZE
  end

  # rebate nas paredes
  if ball[:x] < 0
    ball[:x] = 0
    ball[:direction] = 'right'
  elsif ball[:x] >= WIDTH
    ball[:x] = WIDTH - BLOCK_SIZE
    ball[:direction] = 'left'
  end
  if ball[:y] < 0
    ball[:y] = 0
    ball[:direction] = 'down'
  elsif ball[:y] >= HEIGHT
    ball[:y] = HEIGHT - BLOCK_SIZE
    ball[:direction] = 'up'
  end
end

def hit_wall?(snake)
  head = snake[:body].first
  head[:x] < 0 || head[:x] >= WIDTH || head[:y] < 0 || head[:y] >= HEIGHT
end

def hit_self?(snake)
  return false if snake[:moves] < 5
  head = snake[:body].first
  snake[:body][1..].any? { |s| s == head }
end

def hit_other?(snake, others)
  return false if snake[:moves] < 5
  head = snake[:body].first
  others.any? { |other| other[:body].any? { |s| s == head } }
end

def ate_food?(snake, food)
  head = snake[:body].first
  head[:x] >= food[:x] && head[:x] < food[:x] + BLOCK_SIZE &&
  head[:y] >= food[:y] && head[:y] < food[:y] + BLOCK_SIZE
end

players = {}
snakes = {}
foods = []
crazy_ball = create_crazy_ball  # uma bola maluca no mapa
next_id = 0
golden_food_timer = 0  # contador para aparecer comida dourada
mutex = Mutex.new

server = TCPServer.new(3000)
puts "Servidor iniciado na porta 3000!"

Thread.new do
  loop do
    client = server.accept
    handshake = WebSocket::Handshake::Server.new
    handshake << client.gets("\r\n\r\n")
    client.write(handshake.to_s)

    mutex.synchronize do
      player_id = next_id
      next_id += 1
      pos = START_POSITIONS[player_id % 4]
      snakes[player_id] = create_snake(pos[:x], pos[:y], pos[:direction])
      players[player_id] = client

      # adiciona uma comida normal por jogador
      foods << create_food

      puts "Jogador #{player_id + 1} entrou!"

      welcome = { type: 'welcome', id: player_id, color: PLAYER_COLORS[player_id % 4] }
      frame = WebSocket::Frame::Outgoing::Server.new(version: 13, data: JSON.generate(welcome), type: :text)
      client.write(frame.to_s)

      Thread.new do
        incoming = WebSocket::Frame::Incoming::Server.new
        loop do
          begin
            data = client.recv(1024)
            break if data.nil? || data.empty?
            incoming << data
            while (msg = incoming.next)
              input = JSON.parse(msg.data)
              mutex.synchronize do
                if input['direction'] && snakes[player_id][:alive]
                  dir = input['direction']
                  opposites = { 'right' => 'left', 'left' => 'right', 'up' => 'down', 'down' => 'up' }
                  unless opposites[snakes[player_id][:direction]] == dir
                    snakes[player_id][:direction] = dir
                  end
                end
              end
            end
          rescue
            break
          end
        end
        puts "Jogador #{player_id + 1} saiu!"
        mutex.synchronize do
          snakes[player_id][:alive] = false
          players.delete(player_id)
        end
      end
    end
  end
end

loop do
  sleep 0.15
  next if snakes.empty?

  mutex.synchronize do
    # move a bola maluca
    move_crazy_ball(crazy_ball)

    # verifica se a bola maluca bateu numa cobra
    snakes.each do |id, snake|
      next unless snake[:alive]
      if snake[:body].any? { |s| s[:x] == crazy_ball[:x] && s[:y] == crazy_ball[:y] }
        # cobra perde um bloco mas fica com mínimo de 1
        snake[:body].pop if snake[:body].length > 1
        # bola muda de direção ao bater
        crazy_ball[:direction] = ['right', 'left', 'up', 'down'].sample
      end
    end

    # verifica se a bola maluca bateu numa comida
    foods.each do |food|
      if food[:x] == crazy_ball[:x] && food[:y] == crazy_ball[:y]
        # comida muda de posição
        food[:x] = rand(0..29) * BLOCK_SIZE
        food[:y] = rand(0..29) * BLOCK_SIZE
        crazy_ball[:direction] = ['right', 'left', 'up', 'down'].sample
      end
    end

    # timer para comida dourada — aparece raramente
    golden_food_timer += 1
    if golden_food_timer >= 50 && foods.none? { |f| f[:golden] }
      foods << create_food(golden: true)
      golden_food_timer = 0
      puts "Comida dourada apareceu!"
    end

    # move todas as cobras
    snakes.each do |id, snake|
      next unless snake[:alive]
      move_snake(snake)

      if hit_wall?(snake) || hit_self?(snake)
        snake[:alive] = false
        next
      end

      others = snakes.reject { |other_id, _| other_id == id }.values
      if hit_other?(snake, others)
        snake[:alive] = false
        next
      end

      # verifica se comeu alguma comida
      foods.each_with_index do |food, i|
        if ate_food?(snake, food)
          if food[:golden]
            # comida dourada vale 5 pontos
            snake[:score] += 5
            5.times { snake[:body] << snake[:body].last.dup }
            foods.delete_at(i)  # remove a comida dourada
          else
            # comida normal vale 1 ponto
            snake[:body] << snake[:body].last.dup
            snake[:score] += 1
            foods[i] = create_food  # nova comida normal
          end
        end
      end
    end

    # envia o estado do jogo para todos os jogadores
    state = {
      type: 'state',
      snakes: snakes.map { |id, s| [id, { body: s[:body], alive: s[:alive], score: s[:score], slow: s[:slow_timer] > 0, color: PLAYER_COLORS[id % 4] }] }.to_h,
      foods: foods,
      crazy_ball: crazy_ball
    }

    players.each do |id, client|
      begin
        frame = WebSocket::Frame::Outgoing::Server.new(version: 13, data: JSON.generate(state), type: :text)
        client.write(frame.to_s)
      rescue
        players.delete(id)
      end
    end
  end
end
