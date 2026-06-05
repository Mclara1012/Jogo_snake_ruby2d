require 'socket'    # para criar o servidor TCP
require 'websocket' # para comunicação WebSocket
require 'json'      # para enviar e receber dados em JSON
 
BLOCK_SIZE = 20  # tamanho de cada bloco do jogo
WIDTH = 600      # largura do mapa
HEIGHT = 600     # altura do mapa
 
# cores disponíveis para cada jogador
PLAYER_COLORS = ['green', 'blue', 'orange', 'red']
 
# posições iniciais de cada jogador no mapa
START_POSITIONS = [
  { x: 100, y: 100, direction: 'right' },
  { x: 500, y: 500, direction: 'left' },
  { x: 100, y: 500, direction: 'right' },
  { x: 500, y: 100, direction: 'left' }
]
 
# cria uma cobra com 5 blocos na posição inicial
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
    slow_timer: 0,  # contador de frames que a cobra fica lenta
    moves: 0,       # contador de movimentos feitos
    skip: false     # usado para alternar frames quando lenta
  }
end
 
# cria uma comida numa posição aleatória
# golden: true cria comida dourada que vale 5 pontos
def create_food(golden: false)
  {
    x: rand(0..29) * BLOCK_SIZE,
    y: rand(0..29) * BLOCK_SIZE,
    golden: golden
  }
end
 
# cria a bola maluca que anda sozinha pelo mapa
def create_crazy_ball
  {
    x: rand(0..29) * BLOCK_SIZE,
    y: rand(0..29) * BLOCK_SIZE,
    direction: ['right', 'left', 'up', 'down'].sample,  # direção aleatória
    active: true
  }
end
 
# move a cobra uma posição na direção atual
def move_snake(snake)
  return if !snake[:alive]
 
  # se estiver lenta, salta frames alternados
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
  snake[:body].unshift(new_head)  # adiciona nova cabeça
  snake[:body].pop                # remove a cauda
  snake[:moves] += 1
end
 
# move a bola maluca e faz-a rebater nas paredes
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
 
# verifica se a cobra saiu dos limites do mapa
def hit_wall?(snake)
  head = snake[:body].first
  head[:x] < 0 || head[:x] >= WIDTH || head[:y] < 0 || head[:y] >= HEIGHT
end
 
# verifica se a cobra bateu em si própria
def hit_self?(snake)
  return false if snake[:moves] < 5
  head = snake[:body].first
  snake[:body][1..].any? { |s| s == head }
end
 
# verifica se a cobra bateu noutra cobra
def hit_other?(snake, others)
  return false if snake[:moves] < 5
  head = snake[:body].first
  others.any? { |other| other[:body].any? { |s| s == head } }
end
 
# verifica se a cobra comeu uma comida
def ate_food?(snake, food)
  head = snake[:body].first
  size = food[:golden] ? 30 : BLOCK_SIZE  # comida dourada é maior
  head[:x] >= food[:x] && head[:x] < food[:x] + size &&
  head[:y] >= food[:y] && head[:y] < food[:y] + size
end
 
# estado do jogo
players   = {}  # clientes conectados  { id => socket }
snakes    = {}  # cobras de cada jogador
nicknames = {}  # nicknames de cada jogador { id => string }
 
# comidas iniciais do mapa
foods = []
3.times { foods << create_food }
 
crazy_ball        = create_crazy_ball
next_id           = 0
golden_food_timer = 0
mutex             = Mutex.new
 
# inicia o servidor na porta 3000
server = TCPServer.new(3000)
puts "Servidor iniciado na porta 3000!"
 
# thread para aceitar novos jogadores
Thread.new do
  loop do
    client = server.accept
 
    # handshake WebSocket
    handshake = WebSocket::Handshake::Server.new
    handshake << client.gets("\r\n\r\n")
    client.write(handshake.to_s)
 
    mutex.synchronize do
      player_id = next_id
      next_id += 1
 
      pos = START_POSITIONS[player_id % 4]
      snakes[player_id]    = create_snake(pos[:x], pos[:y], pos[:direction])
      players[player_id]   = client
      nicknames[player_id] = "Jogador#{player_id + 1}"  # default até receber o nick
 
      # envia mensagem de boas vindas com o id e cor do jogador
      welcome = { type: 'welcome', id: player_id, color: PLAYER_COLORS[player_id % 4] }
      frame = WebSocket::Frame::Outgoing::Server.new(version: 13, data: JSON.generate(welcome), type: :text)
      client.write(frame.to_s)
 
      # thread para receber mensagens do jogador
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
 
                # guarda o nickname enviado pelo cliente ao ligar
                if input['type'] == 'nickname'
                  nick = input['nickname'].to_s.strip
                  nick = "Jogador#{player_id + 1}" if nick.empty?
                  nicknames[player_id] = nick
                  puts "#{nick} entrou!"
                  next
                end
 
                # reiniciar jogador sem criar um novo cliente
                if input['type'] == 'restart'
                  pos = START_POSITIONS[player_id % 4]
                  snakes[player_id] = create_snake(pos[:x], pos[:y], pos[:direction])
                  puts "#{nicknames[player_id]} reiniciou!"
                  next
                end
 
                # atualiza a direção da cobra
                if input['direction'] && snakes[player_id] && snakes[player_id][:alive]
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
 
        nick = mutex.synchronize { nicknames[player_id] }
        puts "#{nick} saiu!"
        mutex.synchronize do
          players.delete(player_id)
          snakes.delete(player_id)
          nicknames.delete(player_id)
        end
      end
    end
  end
end
 
# loop principal do jogo
loop do
  sleep 0.15  # velocidade do jogo
  next if snakes.empty?
 
  mutex.synchronize do
    # move a bola maluca
    move_crazy_ball(crazy_ball)
 
    # verifica se a bola maluca bateu numa cobra
    snakes.each do |id, snake|
      next unless snake[:alive]
      if snake[:body].any? { |s| s[:x] == crazy_ball[:x] && s[:y] == crazy_ball[:y] }
        snake[:body].pop if snake[:body].length > 1  # cobra perde um bloco (mínimo 1)
        crazy_ball[:direction] = ['right', 'left', 'up', 'down'].sample
      end
    end
 
    # verifica se a bola maluca bateu numa comida
    foods.each do |food|
      if food[:x] == crazy_ball[:x] && food[:y] == crazy_ball[:y]
        food[:x] = rand(0..29) * BLOCK_SIZE
        food[:y] = rand(0..29) * BLOCK_SIZE
        crazy_ball[:direction] = ['right', 'left', 'up', 'down'].sample
      end
    end
 
    # aparece comida dourada raramente
    golden_food_timer += 1
    if golden_food_timer >= 50 && foods.none? { |f| f[:golden] }
      foods << create_food(golden: true)
      golden_food_timer = 0
      puts "Comida dourada apareceu!"
    end
 
    # move e verifica colisões de todas as cobras
    snakes.each do |id, snake|
      next unless snake[:alive]
      move_snake(snake)
 
      # verifica colisões com paredes e próprio corpo
      if hit_wall?(snake) || hit_self?(snake)
        snake[:alive] = false
        next
      end
 
      # verifica colisões com outras cobras
      others = snakes.reject { |other_id, _| other_id == id }.values
      if hit_other?(snake, others)
        snake[:alive] = false
        next
      end
 
      # verifica se comeu alguma comida
      foods.each_with_index do |food, i|
        if ate_food?(snake, food)
          if food[:golden]
            snake[:score] += 5
            5.times { snake[:body] << snake[:body].last.dup }
            foods.delete_at(i)
          else
            snake[:body] << snake[:body].last.dup
            snake[:score] += 1
            foods[i] = create_food
          end
        end
      end
    end
 
    # envia o estado do jogo para todos os jogadores
    # inclui o nickname de cada cobra no estado
    state = {
      type: 'state',
      snakes: snakes.map do |id, s|
        [id, {
          body:     s[:body],
          alive:    s[:alive],
          score:    s[:score],
          slow:     s[:slow_timer] > 0,
          color:    PLAYER_COLORS[id % 4],
          nickname: nicknames[id] || "Jogador#{id + 1}"
        }]
      end.to_h,
      foods:      foods,
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
