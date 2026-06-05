require 'ruby2d'
require 'websocket'
require 'socket'
require 'json'
 
if ARGV[0]
  server_ip = ARGV[0]
else
  print "IP do servidor (ex: 192.168.193.226): "
  server_ip = gets.chomp
end
 
if ARGV[1]
  nickname = ARGV[1]
else
  print "Insira um nickname: "
  nickname = gets.chomp
  nickname = "Jogador" if nickname.strip.empty?
end
 
WINDOW_W  = 800
WINDOW_H  = 800
BLOCK_SIZE = 20
FOOD_SIZE  = 20
 
set title: 'Snake'
set width:  WINDOW_W
set height: WINDOW_H
set background: 'black'
set fps_cap: 10
 
socket = TCPSocket.new(server_ip, 3000)
 
handshake = WebSocket::Handshake::Client.new(url: "ws://#{server_ip}:3000")
socket.write(handshake.to_s)
socket.gets("\r\n\r\n")
 
puts "Ligado ao servidor!"
 
begin
  nick_msg = { type: 'nickname', nickname: nickname }
  frame = WebSocket::Frame::Outgoing::Client.new(version: 13, data: JSON.generate(nick_msg), type: :text)
  socket.write(frame.to_s)
rescue => e
  puts "Erro ao enviar nickname: #{e}"
end
 
game_state = {}
player_id  = nil
direction  = 'right'
 
Thread.new do
  incoming = WebSocket::Frame::Incoming::Client.new
  loop do
    begin
      data = socket.recv(4096)
      break if data.nil? || data.empty?
      incoming << data
      while (msg = incoming.next)
        parsed = JSON.parse(msg.data)
        if parsed['type'] == 'welcome'
          player_id = parsed['id']
          puts "Entraste como #{nickname}!"
        elsif parsed['type'] == 'state'
          game_state = parsed
        end
      end
    rescue
      break
    end
  end
end
 
update do
  clear
 
  begin
    input = { direction: direction }
    frame = WebSocket::Frame::Outgoing::Client.new(version: 13, data: JSON.generate(input), type: :text)
    socket.write(frame.to_s)
  rescue
  end
 
  next if game_state.empty?
 
  # --- comidas ---
  game_state['foods']&.each do |food|
    if food['golden']
      Square.new(x: food['x'], y: food['y'], size: FOOD_SIZE + 10, color: 'yellow')
      Text.new('★', x: food['x'] + 5, y: food['y'], size: 15, color: 'white')
    else
      Square.new(x: food['x'], y: food['y'], size: FOOD_SIZE, color: 'white')
    end
  end
 
  # --- projéteis ---
  game_state['bullets']&.each do |bullet|
    owner_color = game_state['snakes']&.dig(bullet['owner_id'].to_s, 'color') || 'white'
    Circle.new(
      x:      bullet['x'] + BLOCK_SIZE / 2,
      y:      bullet['y'] + BLOCK_SIZE / 2,
      radius: BLOCK_SIZE / 2,
      color:  owner_color
    )
  end
 
  # --- cobras ---
  game_state['snakes']&.each do |id, snake|
    next unless snake['alive']
    is_me      = id.to_i == player_id
    head_color = is_me ? 'lime' : snake['color']
    body_color = snake['color']
 
    snake['body'].each_with_index do |segment, index|
      color = index == 0 ? head_color : body_color
      Square.new(x: segment['x'], y: segment['y'], size: BLOCK_SIZE, color: color)
    end
  end
 
  # --- game over ---
  if player_id &&
     game_state['snakes'] &&
     game_state['snakes'][player_id.to_s] &&
     !game_state['snakes'][player_id.to_s]['alive']
 
    Text.new("Game Over!",           x: 270, y: 350, size: 30, color: 'red')
    Text.new("Prime R para reiniciar", x: 220, y: 395, size: 20, color: 'white')
    Text.new("Prime S para sair",      x: 260, y: 425, size: 20, color: 'white')
  end
 
  # --- pontuações ---
  game_state['snakes']&.each_with_index do |(id, snake), i|
    nick   = snake['nickname'] || "P#{id.to_i + 1}"
    label  = id.to_i == player_id ? " (tu)" : ""
    slow   = snake['slow'] ? " ~lento~" : ""
    status = snake['alive'] ? "#{nick}#{label}#{slow}: #{snake['score']}" : "#{nick}#{label}: MORTO"
    Text.new(status, x: 10 + (i * 200), y: 10, size: 14, color: snake['color'])
  end
end
 
# controlos de movimento
on :key_held do |event|
  case event.key
  when 'up',    'w' then direction = 'up'
  when 'down',  's' then direction = 'down'
  when 'left',  'a' then direction = 'left'
  when 'right', 'd' then direction = 'right'
  end
end
 
on :key_down do |event|
  case event.key
 
  # disparo
  when 'space'
    if player_id &&
       game_state['snakes'] &&
       game_state['snakes'][player_id.to_s] &&
       game_state['snakes'][player_id.to_s]['alive']
      begin
        shoot = { type: 'shoot' }
        frame = WebSocket::Frame::Outgoing::Client.new(
          version: 13, data: JSON.generate(shoot), type: :text
        )
        socket.write(frame.to_s)
      rescue => e
        puts e
      end
    end
 
  # reiniciar após morrer
  when 'r'
    if player_id &&
       game_state['snakes'] &&
       game_state['snakes'][player_id.to_s] &&
       !game_state['snakes'][player_id.to_s]['alive']
      begin
        frame = WebSocket::Frame::Outgoing::Client.new(
          version: 13, data: JSON.generate({ type: 'restart' }), type: :text
        )
        socket.write(frame.to_s)
        puts "Pedido de reinício enviado."
      rescue => e
        puts e
      end
    end
 
  # sair do jogo
  when 'escape'
    puts "A sair..."
    socket.close rescue nil
    exit
  end
end
 
show
 
