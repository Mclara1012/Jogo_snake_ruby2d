require 'socket'
require 'websocket'
require 'json'
 
BLOCK_SIZE = 20
WIDTH  = 800
HEIGHT = 800
 
PLAYER_COLORS = ['green', 'blue', 'orange', 'red']
 
START_POSITIONS = [
  { x: 100, y: 100, direction: 'right' },
  { x: 700, y: 700, direction: 'left'  },
  { x: 100, y: 700, direction: 'right' },
  { x: 700, y: 100, direction: 'left'  }
]
 
GRID_W = WIDTH  / BLOCK_SIZE  # 40
GRID_H = HEIGHT / BLOCK_SIZE  # 40
MIN_FOODS = 5   # mínimo de comidas normais no mapa
 
def create_snake(x, y, direction)
  body = []
  5.times { |i| body << { x: x - (i * BLOCK_SIZE), y: y } }
  {
    body:       body,
    direction:  direction,
    alive:      true,
    score:      0,
    slow_timer: 0,
    moves:      0,
    skip:       false
  }
end
 
def create_food(golden: false)
  {
    x:      rand(0..(GRID_W - 1)) * BLOCK_SIZE,
    y:      rand(0..(GRID_H - 1)) * BLOCK_SIZE,
    golden: golden
  }
end
 
# cria um projétil disparado por uma cobra
def create_bullet(head, direction, owner_id)
  {
    x:        head[:x],
    y:        head[:y],
    direction: direction,
    owner_id:  owner_id,
    active:    true
  }
end
 
def move_snake(snake)
  return unless snake[:alive]
 
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
 
def move_bullet(bullet)
  case bullet[:direction]
  when 'right' then bullet[:x] += BLOCK_SIZE
  when 'left'  then bullet[:x] -= BLOCK_SIZE
  when 'up'    then bullet[:y] -= BLOCK_SIZE
  when 'down'  then bullet[:y] += BLOCK_SIZE
  end
  # desativa se sair do mapa
  if bullet[:x] < 0 || bullet[:x] >= WIDTH || bullet[:y] < 0 || bullet[:y] >= HEIGHT
    bullet[:active] = false
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
  size = food[:golden] ? 30 : BLOCK_SIZE
  head[:x] >= food[:x] && head[:x] < food[:x] + size &&
  head[:y] >= food[:y] && head[:y] < food[:y] + size
end
 
# --- estado global ---
players   = {}
snakes    = {}
nicknames = {}
bullets   = []   # lista de projéteis ativos
 
foods = []
6.times { foods << create_food }    # começa com 6 comidas normais
 
next_id           = 0
golden_food_timer = 0
mutex             = Mutex.new
 
server = TCPServer.new(3000)
puts "Servidor iniciado na porta 3000!"
 
# --- aceitar ligações ---
Thread.new do
  loop do
    client = server.accept
 
    handshake = WebSocket::Handshake::Server.new
    handshake << client.gets("\r\n\r\n")
    client.write(handshake.to_s)
 
    mutex.synchronize do
      player_id = next_id
      next_id  += 1
 
      pos = START_POSITIONS[player_id % 4]
      snakes[player_id]    = create_snake(pos[:x], pos[:y], pos[:direction])
      players[player_id]   = client
      nicknames[player_id] = "Jogador#{player_id + 1}"
 
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
 
                # nickname
                if input['type'] == 'nickname'
                  nick = input['nickname'].to_s.strip
                  nick = "Jogador#{player_id + 1}" if nick.empty?
                  nicknames[player_id] = nick
                  puts "#{nick} entrou!"
                  next
                end
 
                # reiniciar
                if input['type'] == 'restart'
                  pos = START_POSITIONS[player_id % 4]
                  snakes[player_id] = create_snake(pos[:x], pos[:y], pos[:direction])
                  puts "#{nicknames[player_id]} reiniciou!"
                  next
                end
 
                # disparo — barra de espaço
                if input['type'] == 'shoot' && snakes[player_id] && snakes[player_id][:alive]
                  snake = snakes[player_id]
                  if snake[:body].length > 2
                    # perde 2 blocos
                    2.times { snake[:body].pop if snake[:body].length > 1 }
                    # fica lenta por 10 frames
                    snake[:slow_timer] = 10
                    # cria o projétil à frente da cabeça
                    head = snake[:body].first
                    bullets << create_bullet(head, snake[:direction], player_id)
                  end
                  next
                end
 
                # direção
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
 
# --- loop principal ---
loop do
  sleep 0.15
  next if snakes.empty?
 
  mutex.synchronize do
 
    # move projéteis e verifica colisões
    bullets.each do |bullet|
      next unless bullet[:active]
      move_bullet(bullet)
      next unless bullet[:active]
 
      snakes.each do |id, snake|
        next unless snake[:alive]
        next if id == bullet[:owner_id]  # não acerta no próprio dono
 
        if snake[:body].any? { |s| s[:x] == bullet[:x] && s[:y] == bullet[:y] }
          # acertou — cobra perde 2 blocos
          2.times { snake[:body].pop if snake[:body].length > 1 }
          snake[:slow_timer] = 10
          bullet[:active] = false
          puts "#{nicknames[bullet[:owner_id]]} acertou em #{nicknames[id]}!"
          break
        end
      end
    end
    bullets.reject! { |b| !b[:active] }
 
    # comida dourada
    golden_food_timer += 1
    if golden_food_timer >= 50 && foods.none? { |f| f[:golden] }
      foods << create_food(golden: true)
      golden_food_timer = 0
      puts "Comida dourada apareceu!"
    end
 
    # garante mínimo de comidas normais
    normal_count = foods.count { |f| !f[:golden] }
    (MIN_FOODS - normal_count).times { foods << create_food } if normal_count < MIN_FOODS
 
    # move cobras e colisões
    snakes.each do |id, snake|
      next unless snake[:alive]
      move_snake(snake)
 
      if hit_wall?(snake) || hit_self?(snake)
        snake[:alive] = false
        next
      end
 
      others = snakes.reject { |oid, _| oid == id }.values
      if hit_other?(snake, others)
        snake[:alive] = false
        next
      end
 
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
 
    # envia estado
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
      foods:   foods,
      bullets: bullets.select { |b| b[:active] }
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
