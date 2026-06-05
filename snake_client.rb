require 'ruby2d'
require 'websocket'
require 'socket'
require 'json'

print "IP do servidor (ex: 192.168.1.1): "
server_ip = gets.chomp

set title: 'Snake'
set width: 600
set height: 600
set background: 'black'
set fps_cap: 10

BLOCK_SIZE = 20
FOOD_SIZE = 20

socket = TCPSocket.new(server_ip, 3000)

handshake = WebSocket::Handshake::Client.new(url: "ws://#{server_ip}:3000")
socket.write(handshake.to_s)
socket.gets("\r\n\r\n")

puts "Ligado ao servidor!"

game_state = {}
player_id = nil
direction = 'right'

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
          puts "És o jogador #{player_id + 1}!"
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

  # desenha as comidas
  game_state['foods']&.each do |food|
    # comida dourada é amarela brilhante e maior, comida normal é branca
    if food['golden']
      Square.new(x: food['x'], y: food['y'], size: FOOD_SIZE + 10, color: 'yellow')
      Text.new('⭐', x: food['x'], y: food['y'], size: 15, color: 'gold')
    else
      Square.new(x: food['x'], y: food['y'], size: FOOD_SIZE, color: 'white')
    end
  end

  # desenha a bola maluca
  if game_state['crazy_ball']
    ball = game_state['crazy_ball']
    Circle.new(x: ball['x'] + BLOCK_SIZE / 2, y: ball['y'] + BLOCK_SIZE / 2, radius: BLOCK_SIZE / 2, color: 'white')
  end

  # desenha todas as cobras
  game_state['snakes']&.each do |id, snake|
    next unless snake['alive']
    is_me = id.to_i == player_id
    head_color = is_me ? 'lime' : snake['color']
    body_color = snake['color']

    snake['body'].each_with_index do |segment, index|
      color = index == 0 ? head_color : body_color
      Square.new(x: segment['x'], y: segment['y'], size: BLOCK_SIZE, color: color)
    end
  end

  # mostra as pontuações
  game_state['snakes']&.each_with_index do |(id, snake), i|
    label = id.to_i == player_id ? "(tu)" : ""
    status = snake['alive'] ? "P#{id.to_i + 1}#{label}: #{snake['score']}" : "P#{id.to_i + 1}#{label}: MORTO"
    Text.new(status, x: 10 + (i * 150), y: 10, size: 15, color: snake['color'])
  end
end

on :key_held do |event|
  case event.key
  when 'up', 'w'    then direction = 'up'
  when 'down', 's'  then direction = 'down'
  when 'left', 'a'  then direction = 'left'
  when 'right', 'd' then direction = 'right'
  end
end

show
