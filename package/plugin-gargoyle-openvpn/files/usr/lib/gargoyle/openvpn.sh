#!/bin/sh



# global config directory
OPENVPN_DIR="/etc/openvpn"

# init script
OPENVPN_INIT_SCRIPT="/etc/init.d/openvpn"

server_regenerate_credentials="false"

##################################################
# detect path for EASY RSA automatically
#
# if we're on a system other than debian/gargoyle
# thes may need to be updated.  
#
# If EASY_RSA_PATH variable is exported in calling shell script
# that will get detected here and used
#
################################################################
if [ -z "$EASY_RSA_PATH" ] ; then
	
	debian_ubuntu_easyrsa_path="/usr/share/doc/openvpn/examples/easy-rsa/2.0"
	gargoyle_easyrsa_path="/usr/lib/easy-rsa"

	if [ -d "$debian_ubuntu_easyrsa_path" ] ; then
		EASY_RSA_PATH="$debian_ubuntu_easyrsa_path"
	elif [ -d "$gargoyle_easyrsa_path" ] ; then
		EASY_RSA_PATH="$gargoyle_easyrsa_path"
	fi
fi
if [ -z "$EASY_RSA_PATH" ] ; then
	echo "ERROR: could not find easy-rsa library, exiting"
	exit
fi


random_string()
{
	if [ ! -n "$1" ];
		then LEN=15
		else LEN="$1"
	fi

	echo $(</dev/urandom tr -dc a-z | head -c $LEN) # generate a random string
}


load_def()
{
	passed_var_def="$1"
	vpn_var="$2"
	default="$3"

	result=""
	if [ -z "$passed_var_def" ] ; then passed_var_def=$default ; fi
	if [ "$passed_var_def" = "true" ] || [ "$passed_var_def" = "1" ] ; then result="$vpn_var" ; fi
	
	
	printf "$result"

}

copy_if_diff()
{
	new_file="$1"
	old_file="$2"

	if   [ ! -f "$new_file" ] ; then
		return
	elif [ ! -f "$old_file" ] ; then
		cp "$new_file" "$old_file"
	else
		old_md5=$(md5sum "$old_file" | cut -f 1 -d " ")
		new_md5=$(md5sum "$new_file" | cut -f 1 -d " ")
		if [ "$old_md5" != "$new_md5" ] ; then
			cp "$new_file" "$old_file"
		fi	
	fi
}

create_server_conf()
{
	#required
	openvpn_server_internal_ip="$1"
	openvpn_netmask="$2"
	openvpn_port="$3"
	
	#optional
	openvpn_server_local_subnet_ip="$4"
	openvpn_server_local_subnet_mask="$5"

	#optional, but with defaults
	openvpn_protocol="$6"
	if [ -z "$openvpn_protocol" ] ; then openvpn_protocol="udp" ; fi
	if [ "$openvpn_protocol" = "tcp" ] ; then openvpn_protocol="tcp-server" ; fi

	openvpn_cipher="$7"
	if [ -z "$openvpn_cipher" ] ; then openvpn_cipher="BF-CBC" ; fi
	openvpn_keysize="$8"
	if [ -z "$openvpn_keysize" ] && [ "$openvpn_cipher" = "BF-CBC" ] ; then openvpn_keysize="128" ; fi
	if [ -n "$openvpn_keysize" ] ; then openvpn_keysize="keysize               $openvpn_keysize" ; fi


	openvpn_client_to_client=$(load_def "$9" "client-to-client" "false")
	openvpn_duplicate_cn=$(load_def "${10}" "duplicate-cn" "false")
	openvpn_redirect_gateway=$(load_def "${11}" "push \"redirect-gateway def1\"" "true")

	openvpn_regenerate_cert="${12}"


	if [ ! -f "$OPENVPN_DIR/ca.crt" ]  || [ ! -f "$OPENVPN_DIR/dh1024.pem" ] || [ ! -f "$OPENVPN_DIR/server.crt" ] || [ ! -f "$OPENVPN_DIR/server.key" ] ; then
		openvpn_regenerate_cert="true"
	fi
	server_regenerate_credentials="$openvpn_regenerate_cert"

	mkdir -p "$OPENVPN_DIR/client_conf"
	mkdir -p "$OPENVPN_DIR/ccd"
	mkdir -p "$OPENVPN_DIR/route_data"
	
	random_dir_num=$(random_string)
	random_dir="/tmp/ovpn-client-${random_dir_num}"
	mkdir -p "$random_dir"



	if [ "$openvpn_regenerate_cert" = "true" ] || [ "$openvpn_regenerate_cert" = "1" ] ; then

		cd "$random_dir"
		cp -r "$EASY_RSA_PATH/"* .
		mkdir keys

		name=$( random_string 15 )
		random_domain=$( random_string 15 )
		cat << 'EOF' >vars
export EASY_RSA="`pwd`"
export OPENSSL="openssl"
export PKCS11TOOL="pkcs11-tool"
export GREP="grep"
export KEY_CONFIG=`$EASY_RSA/whichopensslcnf $EASY_RSA`
export KEY_DIR="$EASY_RSA/keys"
export KEY_SIZE=1024
export CA_EXPIRE=99999
export KEY_EXPIRE=99999
export KEY_COUNTRY="??"
export KEY_PROVINCE="UnknownProvince"
export KEY_CITY="UnknownCity"
export KEY_ORG="UnknownOrg"
export KEY_OU="UnknownOrgUnit"
EOF
cat << EOF >>vars
export KEY_EMAIL='$name@$random_domain.com'
export KEY_EMAIL='$name@$random_domain.com'
export KEY_CN='$name'
export KEY_NAME='$name'
EOF
		. ./vars
		./clean-all
		./build-dh
		./pkitool --initca
		./pkitool --server server
		cp keys/server.crt keys/server.key keys/ca.crt keys/ca.key keys/dh1024.pem "$OPENVPN_DIR"/
	fi

	touch "$OPENVPN_DIR/server.conf"
	touch "$OPENVPN_DIR/route_data/server"
	touch "$random_dir/route_data_server"

	# server config
	cat << EOF >"$random_dir/server.conf"
mode                  server
port                  $openvpn_port
proto                 $openvpn_protocol
tls-server
ifconfig              $openvpn_server_internal_ip $openvpn_netmask
topology              subnet
client-config-dir     $OPENVPN_DIR/ccd
$openvpn_client_to_client
$openvpn_duplicate_cn


cipher                $openvpn_cipher
$openvpn_keysize

dev         	      tun
keepalive   	      25 180
status       	      $OPENVPN_DIR/current_status.log
verb         	      5


ca                    $OPENVPN_DIR/ca.crt
dh		      $OPENVPN_DIR/dh1024.pem
cert		      $OPENVPN_DIR/server.crt
key		      $OPENVPN_DIR/server.key


persist-key
persist-tun
comp-lzo

push "route-gateway $openvpn_server_internal_ip"
$openvpn_redirect_gateway

EOF
	if [ -n "$openvpn_server_local_subnet_ip" ] && [ -n "$openvpn_server_local_subnet_mask" ] ; then
		# save routes -- we need to update all route lines 
		# once all client ccd files are in place on the server
		echo "$openvpn_server_local_subnet_ip $openvpn_server_local_subnet_mask $openvpn_server_internal_ip" > "$random_dir/route_data_server"
	fi

	copy_if_diff "$random_dir/server.conf"        "$OPENVPN_DIR/server.conf"
	copy_if_diff "$random_dir/route_data_server"  "$OPENVPN_DIR/route_data/server"


	cd /tmp
	rm -rf "$random_dir"

}



create_allowed_client_conf()
{

	#required
	openvpn_client_id="$1"
	openvpn_client_remote="$2"

	#optional
	openvpn_client_internal_ip="$3"
	openvpn_client_local_subnet_ip="$4"
	openvpn_client_local_subnet_mask="$5"

	#load from server config
	openvpn_protocol=$( awk ' $1 ~ /proto/     { print $2 } ' /etc/openvpn/server.conf )
	openvpn_port=$(     awk ' $1 ~ /port/      { print $2 } ' /etc/openvpn/server.conf )
	openvpn_netmask=$(  awk ' $1 ~ /ifconfig/  { print $3 } ' /etc/openvpn/server.conf )
	if [ "$openvpn_proto" = "tcp-server" ] ; then
		openvpn_proto="tcp-client"
	fi
	
	openvpn_regenerate_cert="$6"
	client_enabled="$7"
	if [ -z "$client_enabled" ] ; then
		client_enabled="true"
	fi

	client_conf_dir="$OPENVPN_DIR/client_conf/$openvpn_client_id"
	if [ ! -f "$client_conf_dir/$openvpn_client_id.crt" ]  || [ ! -f "$client_conf_dir/$openvpn_client_id.key" ] || [ ! -f "$client_conf_dir/ca.crt" ]  ; then
		openvpn_regenerate_cert="true"
	fi

	#if we regenerated server credentials, force regeneration of client credentials too
	if [ "$server_regenerate_credentials" = "true" ] || [ "$server_regenerate_credentials" = "1" ] ; then
		openvpn_regenerate_cert="true"
	fi

	mkdir -p "$OPENVPN_DIR/client_conf"
	mkdir -p "$OPENVPN_DIR/ccd"
	mkdir -p "$OPENVPN_DIR/route_data"
	
	random_dir_num=$(random_string)
	random_dir="/tmp/ovpn-client-${random_dir_num}"
	mkdir -p "$random_dir"



	if [ "$openvpn_regenerate_cert" = "true" ] || [ "$openvpn_regenerate_cert" = "1" ] ; then

		cd "$random_dir"
		cp -r "$EASY_RSA_PATH/"* .
		mkdir keys

		random_domain=$( random_string 15 )
		cat << 'EOF' >vars
export EASY_RSA="`pwd`"
export OPENSSL="openssl"
export PKCS11TOOL="pkcs11-tool"
export GREP="grep"
export KEY_CONFIG=`$EASY_RSA/whichopensslcnf $EASY_RSA`
export KEY_DIR="$EASY_RSA/keys"
export KEY_SIZE=1024
export CA_EXPIRE=99999
export KEY_EXPIRE=99999
export KEY_COUNTRY="??"
export KEY_PROVINCE="UnknownProvince"
export KEY_CITY="UnknownCity"
export KEY_ORG="UnknownOrg"
export KEY_OU="UnknownOrgUnit"
EOF
		cat << EOF >>vars
export KEY_EMAIL='$openvpn_client_id@$randomDomain.com'
export KEY_EMAIL='$openvpn_client_id@$randomDomain.com'
export KEY_CN='$openvpn_client_id'
export KEY_NAME='$openvpn_client_id'
EOF
		. ./vars
		./clean-all
		cp "$OPENVPN_DIR/server.crt" "$OPENVPN_DIR/server.key" "$OPENVPN_DIR/ca.crt"  "$OPENVPN_DIR/ca.key" "$OPENVPN_DIR/dh1024.pem" ./keys/

	
		./pkitool "$openvpn_client_id"

		mkdir -p "$OPENVPN_DIR/client_conf/$openvpn_client_id"
		cp "keys/$openvpn_client_id.crt" "keys/$openvpn_client_id.key" "$OPENVPN_DIR/ca.crt" "$client_conf_dir/"
		
	fi

	
	
	
	
	if [ "$client_enabled" != "false" ] || [ "$client_enabled" != "0" ] ; then
		if [ ! -e "$OPENVPN_DIR/$openvpn_client_id.crt" ] ; then
			ln -s "$OPENVPN_DIR/client_conf/$openvpn_client_id/$openvpn_client_id.crt" "$OPENVPN_DIR/$openvpn_client_id.crt"
		fi
		touch "$OPENVPN_DIR/route_data_${openvpn_client_id}"
		touch "$random_dir/route_data_${openvpn_client_id}"

	else
		if [ -e "$OPENVPN_DIR/$openvpn_client_id.crt" ] ; then
			rm "$OPENVPN_DIR/$openvpn_client_id.crt"
		fi
		if [ -e "$OPENVPN_DIR/route_data/${openvpn_client_id}" ] ; then
			rm "$OPENVPN_DIR/route_data/${openvpn_client_id}" 
		fi
	fi

		

	touch "$random_dir/ccd_${openvpn_client_id}"
	touch "$OPENVPN_DIR/ccd/${openvpn_client_id}"


	cat << EOF >"$random_dir/$openvpn_client_id.conf"

client
remote		$openvpn_client_remote $openvpn_port
dev             tun
proto           $openvpn_protocol
status          $OPENVPN_DIR/current_status.log
resolv-retry    infinite
ns-cert-type	server
topology        subnet
verb            5

ca              $OPENVPN_DIR/ca.crt
cert            $OPENVPN_DIR/$openvpn_client_id.crt
key             $OPENVPN_DIR/$openvpn_client_id.key

nobind
persist-key
persist-tun
comp-lzo
EOF


	#update info about assigned ip/subnet
	if [ -n "$openvpn_client_internal_ip" ] ; then
		echo "ifconfig-push $openvpn_client_internal_ip $openvpn_netmask"                                                                      > "$random_dir/ccd_${openvpn_client_id}"
		if [ -n "$openvpn_client_local_subnet_ip" ] && [ -n "$openvpn_client_local_subnet_mask" ] ; then
			echo "iroute $openvpn_client_local_subnet_ip $openvpn_client_local_subnet_mask"                                               >> "$random_dir/ccd_${openvpn_client_id}"

			# save routes -- we need to update all route lines 
			# once all client ccd files are in place on the server
			if  [ "$client_enabled" != "false" ] || [ "$client_enabled" != "0" ] ; then
				echo "$openvpn_client_local_subnet_ip $openvpn_client_local_subnet_mask $openvpn_client_internal_ip \"$openvpn_client_id\"" > "$random_dir/route_data_${openvpn_client_id}"
			fi
		fi
	fi
	
	copy_if_diff "$random_dir/$openvpn_client_id.conf"          "$client_conf_dir/$openvpn_client_id.conf"
	copy_if_diff "$random_dir/ccd_${openvpn_client_id}"         "$OPENVPN_DIR/ccd/${openvpn_client_id}"
	if  [ "$client_enabled" != "false" ] || [ "$client_enabled" != "0" ] ; then
		copy_if_diff "$random_dir/route_data_${openvpn_client_id}"  "$OPENVPN_DIR/route_data/${openvpn_client_id}"
	fi

	cd /tmp
	rm -rf "$random_dir"
}


update_routes()
{
	openvpn_server_internal_ip=$(awk ' $1 ~ /ifconfig/  { print $2 } ' /etc/openvpn/server.conf )


	# Change "Internal Field Separator" (IFS variable)
	# which controls separation in for loop variables
	IFS_ORIG="$IFS"
	IFS_LINEBREAK="$(printf '\n\r')"
	IFS="$IFS_LINEBREAK"
	
	
	random_dir_num=$(random_string)
	random_dir="/tmp/ovpn-client-${random_dir_num}"
	mkdir -p "$random_dir"
	cp -r "$OPENVPN_DIR/ccd" "$random_dir"/
	cp -r "$OPENVPN_DIR/server.conf" "$random_dir"/
	
	
	# clear out old route data
	for client_ccd_file in "$random_dir/ccd/"* ; do
		sed -i '/^push .*route/d' "$client_ccd_file"
	done
	sed -i '/^route /d' "$random_dir/server.conf"
	
	
	# set updated route data
	route_lines=$( cat "$OPENVPN_DIR/route_data/"* )
	for route_line in $route_lines ; do
		line_parts=$(  echo "$route_line" | awk '{ print NF }')
		subnet_ip=$(   echo "$route_line" | awk '{ print $1 }')
		subnet_mask=$( echo "$route_line" | awk '{ print $2 }')
		openvpn_ip=$(  echo "$route_line" | awk '{ print $3 }')

		if [ $line_parts -gt 3 ] ; then
			# routes for client subnet
			config_name=$( echo "$route_line" | sed 's/\"$//g' | sed 's/^.*\"//g')
			for client_ccd_file in "$random_dir/ccd/"* ; do
				if [ "$random_dir/ccd/$config_name" != "$client_ccd_file" ] ; then
					echo "push \"route $subnet_ip $subnet_mask $openvpn_server_internal_ip\"" >> "$client_ccd_file" 
				fi
			done
			echo "route $subnet_ip $subnet_mask $openvpn_ip" >> "$random_dir/server.conf"

		else
			# routes for server subnet
			for client_ccd_file in "$random_dir/ccd/"* ; do
				echo "push \"route $subnet_ip $subnet_mask $openvpn_ip\"" >> "$client_ccd_file" 
			done
		fi
	done

	cd "$random_dir/ccd/"
	for client_ccd_file in * ; do
		copy_if_diff "$client_ccd_file" "$OPENVPN_DIR/ccd/$client_ccd_file"
	done
	cd "$random_dir"
	copy_if_diff "server.conf" "$OPENVPN_DIR/server.conf"

	cd /tmp
	rm -rf "$random_dir"
	
	
	# change IFS back now that we're done
	IFS="$IFS_ORIG"
}

remove_allowed_client()
{
	client_id="$1"
	rm -rf "$OPENVPN_DIR/client_conf/$current_client"
	rm -rf "$OPENVPN_DIR/$current_client.crt"
	rm -rf "$OPENVPN_DIR/route_data/$current_client"
	rm -rf "$OPENVPN_DIR/ccd/$current_client"
}

generate_test_configuration()
{

	# server
	create_server_conf	10.8.0.1           \
				255.255.255.0      \
				7099               \
				192.168.15.0       \
				255.255.255.0      \
				"tcp"              \
				"BF-CBC"           \
				"128"              \
				"true"             \
				"false"            \
				"true"             \
				"false"



	# clients
	create_allowed_client_conf "client1" "[YOUR_SERVER_IP]" "10.8.0.2" "" "" "false" "true"
	create_allowed_client_conf "client2" "[YOUR_SERVER_IP]" "10.8.0.3" "192.168.16.0" "255.255.255.0" "false" "true"
	create_allowed_client_conf "client3" "[YOUR_SERVER_IP]" "10.8.0.4" "192.168.17.0" "255.255.255.0" "false" "true"

	# update routes
	update_routes 

}

regenerate_allowed_client_from_uci()
{
	section="$1"
	ac_vars="id remote ip subnet_ip subnet_mask regenerate_credentials enabled"
	for var in $ac_vars ; do
		config_get "$var" "$section" "$var"
	done
	if [ "enabled" = "true" ] || [ "enabled" = "1" ] ; then
		create_allowed_client_conf "$id" "$remote" "$ip" "$subnet_ip" "$subnet_mask" "false" "$enabled"
	fi
}


regenerate_server_and_allowed_clients_from_uci()
{
	. /etc/functions.sh
	config_load "openvpn_gargoyle"
	
	server_vars="internal_ip internal_mask port proto cipher keysize client_to_client duplicate_cn redirect_gateway subnet_access regenerate_credentials subnet_ip subnet_mask"
	for var in $server_vars ; do
		config_get "$var" "server" "$var"
	done



	create_server_conf	"$internal_ip"             \
				"$internal_mask"           \
				"$port"                    \
				"$subnet_ip"               \
				"$subnet_mask"             \
				"$proto"                   \
				"$cipher"                  \
				"$keysize"                 \
				"$client_to_client"        \
				"$duplicate_cn"            \
				"$redirect_gateway"        \
				"$regenerate_credentials"


	server_regenerate_credentials="$regenerate_credentials"
	config_foreach regenerate_allowed_client_from_uci "allowed_client"

	for current_client in "$OPENVPN_DIR/client_conf/"* ; do
		if [ -d "$current_client" ] ; then
			current_client=$(echo $current_client | sed 's/^.*\///g')
			client_def=$(uci get openvpn_gargoyle.${current_client} 2>/dev/null)
			if [ "$client_def" != "allowed_client" ] ; then
				remove_allowed_client "$current_client"
			fi
		fi
	done
	

	update_routes

}


# apt-get update
# apt-get install aptitude
# aptitude install -y openvpn
# generate_test_configuration
