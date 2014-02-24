--[[
New change:
Implement a block, which allows to send mesecon signals
after a payment. This could be useful for exclusive access
to specific rooms only for example.
]]

-- New defined for the mesecon part

--[[
The next var indicates the amount ( in seconds ) after which the
mesecon signal is turned off again. Maybe it has to be tuned
a lot before it is useable enough for a specific purpose
]]
local TIME_SETTING = 2

vendor.mese_formspec = function(pos, player)
	local meta = minetest.env:get_meta(pos)
	local node = minetest.env:get_node(pos)
	local description = minetest.registered_nodes[node.name].description;
	local buysell =  "sell"

	local cost = meta:get_int("cost")
	local limit = meta:get_int("limit")
	local formspec = "size[9,7;]"
		.."label[0,0;Configure " .. description .. "]"
		.."field[2,3.0;2,1;cost;Price:;" .. cost .. "]"
		.."label[4,2.75;Price of a signal]"
		.."field[2,4.5;2,1;limit;Sale Limit:;" .. limit .. "]"
		.."label[4,4.15;Total limit of signals]"
		.."label[4,4.45;   (0 for no limit)]"
		.."button[1.5,6;3,0.5;save;Save]"
		.."button_exit[4.5.5,6;3,0.5;close;Save & Close]"
	return formspec
end

vendor.mese_on_receive_fields = function(pos, formname, fields, sender)
	local node = minetest.env:get_node(pos)
	local description = minetest.registered_nodes[node.name].description;
	local meta = minetest.env:get_meta(pos)
	local owner = meta:get_string("owner")
	if sender:get_player_name() ~= owner then
		minetest.chat_send_player(sender:get_player_name(), "vendor:  Cannot configure machine.  The " .. description .. " belongs to " .. owner ..".")
		return
	end

	local cost = tonumber(fields.cost)
	local limit = tonumber(fields.limit)

	if ( cost == nil or cost < 0 ) then
		minetest.chat_send_player(owner, "vendor: Invalid price.  You must enter a positive number for the price.")
		vendor.disable(pos, "Misconfigured")
		return
	end
	if ( limit == nil or limit < 0 ) then
		minetest.chat_send_player(owner, "vendor: Invalid sales limit.  You must enter a positive number (or zero) for the limit.")
		vendor.disable(pos, "Misconfigured")
		return
	end

	meta:set_int("cost", cost)
	meta:set_int("limit", limit)
	meta:set_int("enabled", 1)
	meta:set_string("formspec", vendor.mese_formspec(pos, sender))

	minetest.chat_send_player(owner, "vendor: " .. description .. " is now selling exclusive signals for " .. cost .. money.currency_name)
	vendor.sound_activate(pos)
	vendor.mese_refresh(pos)
end

vendor.mese_refresh = function(pos, err)
	local meta = minetest.env:get_meta(pos)
	local node = minetest.env:get_node_or_nil(pos)
	if ( node == nil ) then
		return
	end

	if ( meta:get_int("enabled") ~= 1 ) then
		return
	end

	local cost = meta:get_int("cost")
	local owner = meta:get_string("owner")
	local limit = meta:get_int("limit")
	local infotext = nil
	local limit_text = ""

	if ( limit > 0 ) then
		limit_text = " (".. limit .. " left)"
	end

	if ( err == nil ) then
		err = ""
	else
		err = err .. ": "
	end

	infotext = err .. owner .. ' Sells exclusive Mesecon Signals for ' .. cost .. money.currency_name .. limit_text

	if ( meta:get_string("infotext") ~= infotext ) then
		meta:set_string("infotext", infotext)
	end
end

vendor.mese_on_punch = function(pos, node, player)
	local meta = minetest.env:get_meta(pos)
	local node = minetest.env:get_node_or_nil(pos)
	if ( node == nil ) then
		return
	end

	local player_name = player:get_player_name()

	local tax = 0
	local cost = meta:get_int("cost")
	local owner = meta:get_string("owner")
	local limit = meta:get_int("limit")
	local enabled = meta:get_int("enabled")

	if not money.has_credit(player_name) then
		minetest.chat_send_player(player_name, "mese_vendor: You don't have credit ('money' privilege).")
		vendor.sound_error(pos)
		return
	end

	if not money.has_credit(owner) then
		vendor.mese_refresh(pos, "Account Suspended")
		vendor.sound_error(pos)
		return
	end

	if ( enabled ~= 1 ) then
		vendor.sound_error(pos)
		return
	end

	local to_account = nil
	local from_account = nil

	to_account = owner
	from_account = player_name

	--[[
	Do the tax check at this point
	]]
	local ocost = cost
	local land_owner = landrush.get_owner(pos)
	if ( land_owner ~= nil and land_owner ~= owner and owner ~= player_name and cost > 10 ) then
		tax = math.floor( cost * vendor.tax )
		if ( tax < 1 ) then
			tax = 1
		end
		cost = cost - tax
	end

	local err = money.transfer(from_account, to_account, cost)
	if ( err ~= nil ) then
		minetest.chat_send_player(player_name, "mese_vendor: Credit transfer failed: " .. err)
		vendor.sound_error(pos)
		return
	end

	-- do the tax transfer
	if ( tax > 0 ) then
		vendor_log_queue(land_owner,{date=os.date("%m/%d/%Y %H:%M"),pos=minetest.pos_to_string(pos),from=from_account,action="Tax",qty=tostring(number),desc="Tax on ".."MeseSignal",amount=tax})
		money.transfer(from_account,land_owner,tax)
	end

	-- The informative part ;)
	minetest.chat_send_player(player_name, "mese_vendor: You bought an exclusive signal from " .. owner .. " for " .. ocost .. money.currency_name)
	vendor_log_queue(to_account,{date=os.date("%m/%d/%Y %H:%M"),pos=minetest.pos_to_string(pos),from=from_account,action="Sale",qty=tostring( 1 ),desc="MeseSignal",amount=cost})
	vendor.sound_vend(pos)

	-- Start the signal and abort after 2s (lag sensitive)
	local tmp_node = minetest.get_node( pos )
	tmp_node.name = 'vendor:signal_vendor_on'
	minetest.swap_node( pos, tmp_node )
	mesecon:receptor_on(pos, mesecon.rules.buttonlike_get(node))
	minetest.after( TIME_SETTING, vendor.signal_vendor_turnoff, pos)
	-- end

	if ( limit > 0 ) then
		limit = limit - 1
		meta:set_int("limit", limit)
		if ( limit == 0 ) then
			vendor.disable(pos, "Sold Out")
		else
			vendor.mese_refresh(pos)
		end
	end
end

vendor.signal_vendor_turnoff = function (pos)
	local node = minetest.env:get_node(pos)
	if node.name=='vendor:signal_vendor_on' then --has not been dug
		local tmp_node = minetest.get_node( pos )
		tmp_node.name = 'vendor:signal_vendor_off'
		minetest.swap_node( pos, tmp_node )
		local rules = mesecon.rules.buttonlike_get(node)
		mesecon:receptor_off(pos, rules)
	end
end


minetest.register_node( 'vendor:signal_vendor_off', {
	description = 'Signal Vendor',
	tile_images = {'vendor_side.png', 'vendor_side.png', 'vendor_side.png',
				'vendor_side.png', 'vendor_side.png', 'vendor_vendor_front.png'},
	paramtype = 'light',
	paramtype2 = 'facedir',
	groups = {snappy=2,choppy=2,oddly_breakable_by_hand=2},
	after_place_node = function( pos, placer )
		print( 'Placed a new signal vendor')
		local meta = minetest.env:get_meta(pos)
		meta:set_int("cost", 0)
		meta:set_int("limit", 0)
		meta:set_string("owner", placer:get_player_name() or "")
		meta:set_string("formspec", vendor.mese_formspec(pos, placer))
		local description = minetest.registered_nodes[minetest.env:get_node(pos).name].description
		vendor.disable(pos, "New " .. description)
	end,
	can_dig = vendor.can_dig,
	on_receive_fields = vendor.mese_on_receive_fields,
	on_punch = vendor.mese_on_punch,
	mesecons = {receptor = {
		state = mesecon.state.off,
		rules = mesecon.rules.buttonlike_get
	}},
	})

minetest.register_node( 'vendor:signal_vendor_on', {
	description = 'Signal Vendor',
	tile_images = {'vendor_side.png', 'vendor_side.png', 'vendor_side.png',
				'vendor_side.png', 'vendor_side.png', 'vendor_vendor_front.png'},
	paramtype = 'light',
	paramtype2 = 'facedir',
	drop = 'vendor:signal_vendor_off',
	groups = {snappy=2,choppy=2,oddly_breakable_by_hand=2},
	mesecons = {receptor = {
		state = mesecon.state.on,
		rules = mesecon.rules.buttonlike_get
	}},
	})

minetest.register_craft({
	output = 'vendor:signal_vendor_off',
	recipe = {
                {'default:wood', 'default:wood', 'default:wood'},
                {'default:wood', 'default:steel_ingot', 'default:wood'},
                {'default:wood', 'mesecons:wire_00000000_off', 'default:wood'},
        }
})
