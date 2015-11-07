module(...,package.seeall)

-- Prototype NFV for Lightweight 4over6 according to
-- https://tools.ietf.org/html/rfc7596
--
-- Adding tunnel type 'lwaftr' to the port definition for snabbnfv
-- with the following format:
--
--    tunnel = {
--          type = "lwaftr",
--            ipv6_interface = {
--            address = "<local ipv6 tunnel endpoint>",
--            next_hop = "<ipv6 next hop address>",
--            next_hop_mac = "<mac-address>",      -- optional
--          },
--          ipv4_interface = {
--            address  = "<local ipv4 address>",
--            next_hop = "<ipv4 next hop address>",
--            next_hop_mac = "<mac-address>",      -- required until arp is supported
--          },
--          binding_table = {
--          -- [binding_ipv6_addr] = binding_ipv4_addr, psid_len, psoffset, psid
--            ["fc00:1:2:3:4:5:7:127"] = "193.5.1.100,6,0,1",  -- example 1
--            ["fc00:1:2:3:4:5:7:128"] = "193.5.1.100,6,0,2",  -- example 2
--            ["fc00:1:2:3:4:5:7:129"] = "193.5.1.100,6,0,3",
--          }
--       }
--    }
--
-- TODO: 
--  MTU and fragmentation handling
--  ARP resolution for ipv4 next_hop
--  ICMP handling according to RFC
--  Performance enhancement (e.g. hash efficiency)
--  Better syntax error handling in config file
--  Implement selftest() function

-- initial code copied from keyed_ipv6_tunnel/tunnel.lua

local AF_INET  = 2
local AF_INET6 = 10

local ffi = require("ffi")
local C = ffi.C
local bit = require("bit")

local helpers = require "syscall.helpers"

local bit = require("bit")
local band, rshift, lshift = bit.band, bit.rshift, bit.lshift

local app = require("core.app")
local link = require("core.link")
local lib = require("core.lib")
local packet = require("core.packet")
local config = require("core.config")

local macaddress = require("lib.macaddress")

local pcap = require("apps.pcap.pcap")
local basic_apps = require("apps.basic.basic_apps")

local ether_header_struct_ctype = ffi.typeof[[
struct {
   // ethernet
   char dmac[6];
   char smac[6];
   uint16_t ethertype;
} __attribute__((packed))
]]

local ipv6_header_struct_ctype = ffi.typeof[[
struct {
   // ipv6
   uint32_t flow_id; // version, tc, flow_id
   int16_t payload_length;
   int8_t  next_header;
   uint8_t hop_limit;
   char src_ip[16];
   char dst_ip[16];
} __attribute__((packed))
]]

local ipv4_header_struct_ctype = ffi.typeof[[
struct {
   // ipv4
   int8_t  version_hdrlen;
   int8_t  diffserv;
   int16_t payload_length;
   int16_t id;
   int16_t flag_fragmet;
   int8_t  ttl;
   int8_t  protocol;
   int16_t header_checksum;
   char    src_ip[4];
   char    dst_ip[4];
   // TCP or UDP
   char    src_port[2];
   char    dst_port[2];
} __attribute__((packed))
]]

-- local ipv4_struct_ctype = ffi.typeof("uint32_t[1]")

local ETHER_HEADER_SIZE = ffi.sizeof(ether_header_struct_ctype)
local IPV6_HEADER_SIZE  = ffi.sizeof(ipv6_header_struct_ctype)
local ETHER_IPV6_HEADER_SIZE = ETHER_HEADER_SIZE + IPV6_HEADER_SIZE

local char_ctype = ffi.typeof("uint8_t[?]")
local pchar_ctype = ffi.typeof("uint8_t*")
local pshort_ctype = ffi.typeof("int16_t*")
local pipv4_addr_ctype = ffi.typeof("uint32_t*")
local pipv6_address_ctype = ffi.typeof("uint64_t*")

local DST_MAC_OFFSET   = ffi.offsetof(ether_header_struct_ctype, 'dmac')
local ETHERTYPE_OFFSET = ffi.offsetof(ether_header_struct_ctype, 'ethertype')

local SRC_IPV6_OFFSET = ffi.offsetof(ipv6_header_struct_ctype, 'src_ip')
local DST_IPV6_OFFSET = ffi.offsetof(ipv6_header_struct_ctype, 'dst_ip')
local IPV6_LENGTH_OFFSET = ffi.offsetof(ipv6_header_struct_ctype, 'payload_length')
local NEXT_HEADER_OFFSET = ffi.offsetof(ipv6_header_struct_ctype, 'next_header')
local FLOW_ID_OFFSET = ffi.offsetof(ipv6_header_struct_ctype, 'flow_id')
local HOP_LIMIT_OFFSET = ffi.offsetof(ipv6_header_struct_ctype, 'hop_limit')

local SRC_IPV4_OFFSET = ffi.offsetof(ipv4_header_struct_ctype, 'src_ip')
local DST_IPV4_OFFSET = ffi.offsetof(ipv4_header_struct_ctype, 'dst_ip')
local IPV4_PROTOCOL_OFFSET = ffi.offsetof(ipv4_header_struct_ctype, 'protocol')
local IPV4_SRC_PORT_OFFSET = ffi.offsetof(ipv4_header_struct_ctype, 'src_port')
local IPV4_DST_PORT_OFFSET = ffi.offsetof(ipv4_header_struct_ctype, 'dst_port')

-- Next Header IPIP (4)
local IPIP_NEXT_HEADER = 0x04

local header_template = char_ctype(ETHER_HEADER_SIZE + ETHER_IPV6_HEADER_SIZE)

local function hex_dump(cdata,len)
  local buf = ffi.string(cdata,len)
  for i=1,math.ceil(#buf/16) * 16 do
    if (i-1) % 16 == 0 then io.write(string.format('%08X  ', i-1)) end
    io.write( i > #buf and '   ' or string.format('%02X ', buf:byte(i)) )
    if i %  8 == 0 then io.write(' ') end
    if i % 16 == 0 then io.write( buf:sub(i-16+1, i):gsub('%c','.'), '\n' ) end
  end
end

-- fill header template with const values
local function prepare_header_template ()
   -- all bytes are zeroed after allocation

   -- IPv6
   header_template[ETHERTYPE_OFFSET] = 0x86
   header_template[ETHERTYPE_OFFSET + 1] = 0xDD

   -- Ver. Set to 0x6 to indicate IPv6.
   -- version is 4 first bits at this offset
   -- no problem to set others 4 bits to zeros - it is already zeros
   header_template[ETHER_HEADER_SIZE + FLOW_ID_OFFSET] = 0x60
   header_template[ETHER_HEADER_SIZE + HOP_LIMIT_OFFSET] = 64
   header_template[ETHER_HEADER_SIZE + NEXT_HEADER_OFFSET] = IPIP_NEXT_HEADER

end

lwaftr = {}

-- Decap path:
--   Key: IPv6 source address
--   Value: IPv4 address that subscriber maps to
--   (reverse check to validate port is required. Could be done by using 
--    encap path array)
map_ipv6_to_ipv4 = {}

-- Encap path:
--   Key: IPv4 destination address and psid (32 + 16 = 48 bits)
--   Value: IPv6 destination address
map_ipv4psid_to_ipv6 = {}
shared_psmask = 0

function lwaftr:new (arg)
   local conf = arg and config.parse_app_arg(arg) or {}
   -- required fields:
   --   local_mac, ipv6_interface.address, ipv4_interface and binding_table
   assert(
         type(conf.ipv6_interface.address) == "string",
         "need ipv6_interface IPv6 address"
      )
   
   local header = char_ctype(ETHER_IPV6_HEADER_SIZE)
   ffi.copy(header, header_template, ETHER_IPV6_HEADER_SIZE)

   -- convert dest, source ipv6 addressed to network order binary
   local result =
      C.inet_pton(AF_INET6, conf.ipv6_interface.address, header + ETHER_HEADER_SIZE + SRC_IPV6_OFFSET)
   assert(result == 1,"malformed IPv6 address: " .. conf.ipv6_interface.address)

   assert( type(conf.binding_table) == "table", "binding_table missing or not a table")

   assert(type(conf.local_mac) == "string", "need local_mac")
   local local_mac = assert(macaddress:new(conf.local_mac))
   local remote_ipv4_mac = assert(macaddress:new(conf.ipv4_interface.next_hop_mac))

   -- walk thru the binding_table and build assoc arrays for remote ipv6 address
   -- and ipv4 plus port mask.

   local count = 0
   for binding_ipv6_addr,binding in pairs(conf.binding_table) do

     count = count + 1
     local next, s = binding:split(',')
     local binding_ipv4_addr, psid_len, psoffset, psid = next(s), next(s), next(s), next(s)
     local pipv4  = ffi.new("uint32_t[1]")
     local result = C.inet_pton(AF_INET, binding_ipv4_addr, pipv4)
     local ipv4 = pipv4[0]
     assert(result == 1,"malformed IPv4 address: " .. binding_ipv4_addr)

     local in_addr6  = ffi.new("uint8_t[16]")
     local result = C.inet_pton(AF_INET6, binding_ipv6_addr, in_addr6)
     assert(result == 1,"malformed IPv6 address: " .. binding_ipv6_addr)

     -- key is just the remote IPv6 address. Unique enough hopefully
     local ipv6key = ffi.string(in_addr6, 16)
     map_ipv6_to_ipv4[ipv6key] = ipv4;

     -- mask = (0xffff >> psoffset) & (0xffff << (16 - psoffset - psidlen))
     -- value = psid << (16 - psoffset - psidlen)
     local psmask = band(rshift(0xffff, psoffset), lshift(0xffff,16 - psoffset - psid_len))
     if shared_psmask > 0 and shared_psmask ~= psmask then
       print("psoffset and psid_len must be the same for all entries")
       os.exit(1)
     else
       shared_psmask = psmask
     end

     local psid = lshift(psid,16 - psoffset - psid_len)
     local ipv4psid = lshift(ipv4,16) + psid
     map_ipv4psid_to_ipv6[ipv4psid] = in_addr6

   end

   if conf.ipv6_interface.next_hop_mac then
      local mac = assert(macaddress:new(conf.ipv6_interface.next_hop_mac))
      ffi.copy(header + DST_MAC_OFFSET, mac.bytes, 6)
   end

   if conf.hop_limit then
      assert(type(conf.hop_limit) == 'number' and
          conf.hop_limit <= 255, "invalid hop limit")
      header[ETHER_HEADER_SIZE + HOP_LIMIT_OFFSET] = conf.hop_limit
   end

   local o =
   {
      header = header,
      map_ipv6_to_ipv4 = map_ipv6_to_ipv4,
      local_mac = local_mac,
      remote_ipv4_mac = remote_ipv4_mac,
      map_ipv4psid_to_ipv6
   }

   print(string.format("%d bindings parsed", count))

   return setmetatable(o, {__index = lwaftr})
end

function lwaftr:push()
   -- encapsulation path
   local l_in = self.input.decapsulated
   local l_out = self.output.encapsulated
   assert(l_in and l_out)

   while not link.empty(l_in) and not link.full(l_out) do
     local p = link.receive(l_in)

     local drop = true
     local dst_ipv6 

     repeat

       local pether = ffi.cast(pshort_ctype, p.data + ETHERTYPE_OFFSET)
       if lib.ntohs(pether[0]) ~= 0x0800 then
         break
       end

--      print ("got IPv4 packet")

       local pdst_ipv4 = ffi.cast(pipv4_addr_ctype, p.data + ETHER_HEADER_SIZE + DST_IPV4_OFFSET)
       local dst_ipv4 = pdst_ipv4[0]
       local pprotocol = ffi.cast(pchar_ctype, p.data + ETHER_HEADER_SIZE + IPV4_PROTOCOL_OFFSET)
       local protocol = pprotocol[0]
       if protocol ~= 6 and protocol ~= 17 then
         break
       end

--       print("TCP or UDP packet found")

       local pdstport = ffi.cast(pshort_ctype, p.data + ETHER_HEADER_SIZE + IPV4_DST_PORT_OFFSET)
       local dstport = lib.ntohs(pdstport[0])
       local psid = 0

       psid = band(dstport,shared_psmask)
       local ipv4psid = lshift(dst_ipv4,16) + psid
       dst_ipv6 = map_ipv4psid_to_ipv6[ipv4psid]
       if dst_ipv6 == nil then
           break
       end
       drop = false

     until true

     if drop then
       -- discard packet
       packet.free(p)
     else
       -- remove ethernet header
       packet.shiftleft(p, ETHER_HEADER_SIZE)
       local pchar = ffi.cast(pchar_ctype, self.header + ETHER_HEADER_SIZE + DST_IPV6_OFFSET)
       ffi.copy(pchar, dst_ipv6, 16)
       packet.prepend(p, self.header, ETHER_HEADER_SIZE + IPV6_HEADER_SIZE)
       local plength = ffi.cast(pshort_ctype, p.data + ETHER_HEADER_SIZE + IPV6_LENGTH_OFFSET)
       plength[0] = lib.htons(p.length - ETHER_HEADER_SIZE - IPV6_HEADER_SIZE)
       link.transmit(l_out, p)
     end
   end

   -- decapsulation path
   l_in = self.input.encapsulated
   l_out = self.output.decapsulated
   assert(l_in and l_out)
   while not link.empty(l_in) and not link.full(l_out) do
      local p = link.receive(l_in)
      -- match next header, cookie, src/dst addresses
      local drop = true
      repeat
         if p.length < ETHER_IPV6_HEADER_SIZE then
            break
         end

--         print ("packet received")

         local next_header = ffi.cast(pchar_ctype, p.data + ETHER_HEADER_SIZE + NEXT_HEADER_OFFSET)
         if next_header[0] ~= IPIP_NEXT_HEADER then
            break
         end

--         print ("ipip found")

         local key = ffi.string(p.data + ETHER_HEADER_SIZE + SRC_IPV6_OFFSET, 16)
         local ipv4 = self.map_ipv6_to_ipv4[key]

         if ipv4 == nil then
           break
         end

--         print("found binding entry for IPv4 ")

         local psrc_ipv4 = ffi.cast(pipv4_addr_ctype, p.data + ETHER_IPV6_HEADER_SIZE + SRC_IPV4_OFFSET)
         local src_ipv4 = psrc_ipv4[0]
         if src_ipv4 ~= ipv4 then
           break
         end

         -- Source IPv4 address is a match. Lets verify the source TCP/UDP port as well.
         
         local pprotocol = ffi.cast(pchar_ctype, p.data + ETHER_IPV6_HEADER_SIZE + IPV4_PROTOCOL_OFFSET)
         local protocol = pprotocol[0]
         -- check for TCP or UDP packet. Discard anything else (TODO fix here for ICMP handling)
         if protocol ~= 6 and protocol ~= 17 then
           break
         end

--         print("its a TCP or UDP packet and its IPv4 source address matches")

         local psrcport = ffi.cast(pshort_ctype, p.data + ETHER_IPV6_HEADER_SIZE + IPV4_SRC_PORT_OFFSET)
         local srcport = lib.ntohs(psrcport[0])

         local psid = band(srcport,shared_psmask)
         local ipv4psid = lshift(src_ipv4,16) + psid
         local src_ipv6 = map_ipv4psid_to_ipv6[ipv4psid]
         if src_ipv6 == nil then
           break
         end
         -- Packet is good!
         drop = false 

      until true

      if drop then
         -- don't drop. Pass it on to the virtual machine unchanged
         link.transmit(l_out, p)
      else
         packet.shiftleft(p, ETHER_IPV6_HEADER_SIZE - 14)  -- leave Ethernet header

         -- set source and destination MAC and ethertype to ipv4
         local pchar = ffi.cast(pchar_ctype, p.data + DST_MAC_OFFSET)
         ffi.copy(pchar, self.remote_ipv4_mac.bytes, 6)
         ffi.copy(pchar + 6, self.local_mac.bytes, 6)

         local pchar = ffi.cast(pchar_ctype, p.data + ETHERTYPE_OFFSET)
         -- IPv4
         pchar[0] = 0x08
         pchar[1] = 0x00
         link.transmit(l_out, p)
      end
   end
end

-- prepare header template to be used by all apps
prepare_header_template()

function selftest ()
   print("Keyed IPv6 tunnel selftest")
   local ok = true

   local input_file = "apps/keyed_ipv6_tunnel/selftest.cap.input"
   local output_file = "apps/keyed_ipv6_tunnel/selftest.cap.output"
   local tunnel_config = {
      local_address = "00::2:1",
      remote_address = "00::2:1",
      local_cookie = "12345678",
      remote_cookie = "12345678",
      default_gateway_MAC = "a1:b2:c3:d4:e5:f6"
   } -- should be symmetric for local "loop-back" test

   local c = config.new()
   config.app(c, "source", pcap.PcapReader, input_file)
   config.app(c, "tunnel", lwaftr, tunnel_config)
   config.app(c, "sink", pcap.PcapWriter, output_file)
   config.link(c, "source.output -> tunnel.decapsulated")
   config.link(c, "tunnel.encapsulated -> tunnel.encapsulated")
   config.link(c, "tunnel.decapsulated -> sink.input")
   app.configure(c)

   app.main({duration = 0.25}) -- should be long enough...
   -- Check results
   if io.open(input_file):read('*a') ~=
      io.open(output_file):read('*a')
   then
      ok = false
   end

   local c = config.new()
   config.app(c, "source", basic_apps.Source)
   config.app(c, "tunnel", lwaftr, tunnel_config)
   config.app(c, "sink", basic_apps.Sink)
   config.link(c, "source.output -> tunnel.decapsulated")
   config.link(c, "tunnel.encapsulated -> tunnel.encapsulated")
   config.link(c, "tunnel.decapsulated -> sink.input")
   app.configure(c)

   print("run simple one second benchmark ...")
   app.main({duration = 1})

   if not ok then
      print("selftest failed")
      os.exit(1)
   end
   print("selftest passed")

end
