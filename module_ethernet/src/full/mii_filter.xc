// Copyright (c) 2011, XMOS Ltd., All rights reserved
// This software is freely distributable under a derivative of the
// University of Illinois/NCSA Open Source License posted in
// LICENSE.txt and at <http://github.xcore.com/>

#include "mii_full.h"
#include "mii_queue.h"
#include "ethernet_server_def.h"
#include "ethernet_conf_derived.h"
#include <xccompat.h>
#include <print.h>
#include "mii_malloc.h"
#include "mii_filter.h"
#include "mac_filter.h"
//#include <xscope.h>

#if ETHERNET_ENABLE_FULL_TIMINGS
// Smallest non-HP packet + interframe gap is 84 bytes = 6.72 us
#pragma xta command "remove exclusion *"
//#if ETHERNET_RX_HP_QUEUE
//#pragma xta command "add exclusion avb_1722_router_table_lookup_simple"
//#endif
#pragma xta command "analyze endpoints rx_packet rx_packet"
#if NUM_ETHERNET_PORTS == 2
#pragma xta command "set required - 3.36 us"
#else
#pragma xta command "set required - 6.72 us"
#endif

#endif

#if ETHERNET_FILTER_ENABLE_USER_DATA
int mac_custom_filter_coerce(int buf, unsigned int mac[], int &user_data);
#else
int mac_custom_filter_coerce(int buf, unsigned int mac[]);
#endif


#define is_broadcast(buf) (mii_packet_get_data(buf,0) & 0x1)
#define compare_mac(buf,mac) (mii_packet_get_data(buf,0) == mac[0] && ((short) mii_packet_get_data(buf,1)) == ((short) mac[1]))

#if ETHERNET_COUNT_PACKETS
static unsigned ethernet_filtered_by_address=0;
static unsigned ethernet_filtered_by_user_filter=0;
static unsigned ethernet_filtered_by_length=0;
static unsigned ethernet_filtered_by_bad_crc=0;

void ethernet_get_filter_counts(unsigned &address, unsigned &filter, unsigned &length, unsigned &crc)
{
    address = ethernet_filtered_by_address;
    filter = ethernet_filtered_by_user_filter;
    length = ethernet_filtered_by_length;
    crc = ethernet_filtered_by_bad_crc;
}
#endif

#pragma unsafe arrays
void ethernet_filter(const char mac_address[], streaming chanend c[NUM_ETHERNET_PORTS]) {
    unsigned int mac[2];
    int buf;
    // create integer version of mac address for speed
    mac[0] = mac_address[0] + (((unsigned) mac_address[1]) << 8)  + (((unsigned) mac_address[2]) << 16)  + (((unsigned) mac_address[3]) << 24);
    mac[1] = (((unsigned) mac_address[4])) + (((unsigned) mac_address[5]) << 8);

    while (1)
    {
        select
        {
#pragma xta endpoint "rx_packet"
            case (int ifnum=0; ifnum<NUM_ETHERNET_PORTS; ifnum++) c[ifnum] :> buf :
            {
                if (buf)
                {
                    int length = mii_packet_get_length(buf);

#if ETHERNET_RX_CRC_ERROR_CHECK
                    unsigned poly = 0xEDB88320;
                    unsigned crc = mii_packet_get_crc(buf);
                    int endbytes;
                    int tail;

                    tail = mii_packet_get_data(buf,((length & 0xFFFFFFFC)/4)+1);

                    endbytes = (length & 3);

                    switch (endbytes)
                    {
                        case 0:
                            break;
                        case 1:
                            tail = crc8shr(crc, tail, poly);
                            break;
                        case 2:
                            tail = crc8shr(crc, tail, poly);
                            tail = crc8shr(crc, tail, poly);
                            break;
                        case 3:
                            tail = crc8shr(crc, tail, poly);
                            tail = crc8shr(crc, tail, poly);
                            tail = crc8shr(crc, tail, poly);
                            break;
                    }
#endif
                    mii_packet_set_src_port(buf, ifnum);

//                    xscope_int(PACKET_LEN, length);
//                    xscope_int(INTERFACE_NUM, ifnum + 1);

                    if (length < 60)
                    {
#if ETHERNET_COUNT_PACKETS
                        ethernet_filtered_by_length++;
#endif
                        mii_packet_set_filter_result(buf, 0);
                        mii_packet_set_stage(buf,1);
#if ETHERNET_RX_TRAP_ON_BAD_PACKET
                        __builtin_trap();
#endif
                    }
#if ETHERNET_RX_CRC_ERROR_CHECK
                    else if (~crc)
                    {
#if ETHERNET_COUNT_PACKETS
                        ethernet_filtered_by_bad_crc++;
#endif
                        mii_packet_set_filter_result(buf, 0);
                        mii_packet_set_stage(buf,1);
#if ETHERNET_RX_TRAP_ON_BAD_PACKET
                        __builtin_trap();
#endif

                    }
#endif
                    else
                    {
                        int filter_result = 0;
                        int user_data = 0;
#if (NUM_ETHERNET_MASTER_PORTS > 1) && !defined(DISABLE_ETHERNET_PORT_FORWARDING)
                        if (1) {
#else
                            int broadcast = is_broadcast(buf);
                            int unicast = compare_mac(buf,mac);
                            if (broadcast || unicast) {
#endif

#if ETHERNET_FILTER_ENABLE_USER_DATA
                            filter_result = mac_custom_filter_coerce(buf, mac, user_data);
#else
                            filter_result = mac_custom_filter_coerce(buf, mac);
#endif

#if ETHERNET_COUNT_PACKETS
                                if (filter_result == 0) ethernet_filtered_by_user_filter++;
#endif
                            } else {
#if ETHERNET_COUNT_PACKETS
                                ethernet_filtered_by_address++;

#endif
                            }
                            // We need to zero the timestamp ID in case the frame is forwarded on another port
                            // so that the TX server does not try to timestamp the frame on egress (and crash)
                            mii_packet_set_timestamp_id(buf, 0);

#if ETHERNET_FILTER_ENABLE_USER_DATA
                            mii_packet_set_user_data(buf, user_data);
#endif

                            mii_packet_set_filter_result(buf, filter_result);
                            mii_packet_set_stage(buf, 1);
                        }


                    }
                    break;
                } // end if (buf)
            } // end case()
        } // end select
    } // end while (1)


#pragma unsafe arrays
void ethernet_filter_single_port(const char mac_address[], streaming chanend c[1]) {
    unsigned int mac[2];
    int buf;
    // create integer version of mac address for speed
    mac[0] = mac_address[0] + (((unsigned) mac_address[1]) << 8)  + (((unsigned) mac_address[2]) << 16)  + (((unsigned) mac_address[3]) << 24);
    mac[1] = (((unsigned) mac_address[4])) + (((unsigned) mac_address[5]) << 8);

    while (1)
    {
        select
        {
#pragma xta endpoint "rx_packet"
            case (int ifnum=0; ifnum<1; ifnum++) c[ifnum] :> buf :
            {
                if (buf)
                {
                    int length = mii_packet_get_length(buf);

#if ETHERNET_RX_CRC_ERROR_CHECK
                    unsigned poly = 0xEDB88320;
                    unsigned crc = mii_packet_get_crc(buf);
                    int endbytes;
                    int tail;

                    tail = mii_packet_get_data(buf,((length & 0xFFFFFFFC)/4)+1);

                    endbytes = (length & 3);

                    switch (endbytes)
                    {
                        case 0:
                            break;
                        case 1:
                            tail = crc8shr(crc, tail, poly);
                            break;
                        case 2:
                            tail = crc8shr(crc, tail, poly);
                            tail = crc8shr(crc, tail, poly);
                            break;
                        case 3:
                            tail = crc8shr(crc, tail, poly);
                            tail = crc8shr(crc, tail, poly);
                            tail = crc8shr(crc, tail, poly);
                            break;
                    }
#endif
                    mii_packet_set_src_port(buf, ifnum);

//                    xscope_int(PACKET_LEN, length);
//                    xscope_int(INTERFACE_NUM, ifnum + 1);

                    if (length < 60)
                    {
#if ETHERNET_COUNT_PACKETS
                        ethernet_filtered_by_length++;
#endif
                        mii_packet_set_filter_result(buf, 0);
                        mii_packet_set_stage(buf,1);
#if ETHERNET_RX_TRAP_ON_BAD_PACKET
                        __builtin_trap();
#endif
                    }
#if ETHERNET_RX_CRC_ERROR_CHECK
                    else if (~crc)
                    {
#if ETHERNET_COUNT_PACKETS
                        ethernet_filtered_by_bad_crc++;
#endif
                        mii_packet_set_filter_result(buf, 0);
                        mii_packet_set_stage(buf,1);
#if ETHERNET_RX_TRAP_ON_BAD_PACKET
                        __builtin_trap();
#endif

                    }
#endif
                    else
                    {
                        int filter_result = 0;
                        int user_data = 0;
#if (NUM_ETHERNET_MASTER_PORTS > 1) && !defined(DISABLE_ETHERNET_PORT_FORWARDING)
                        if (1) {
#else
                            int broadcast = is_broadcast(buf);
                            int unicast = compare_mac(buf,mac);
                            if (broadcast || unicast) {
#endif

#if ETHERNET_FILTER_ENABLE_USER_DATA
                            filter_result = mac_custom_filter_coerce(buf, mac, user_data);
#else
                            filter_result = mac_custom_filter_coerce(buf, mac);
#endif

#if ETHERNET_COUNT_PACKETS
                                if (filter_result == 0) ethernet_filtered_by_user_filter++;
#endif
                            } else {
#if ETHERNET_COUNT_PACKETS
                                ethernet_filtered_by_address++;

#endif
                            }
                            // We need to zero the timestamp ID in case the frame is forwarded on another port
                            // so that the TX server does not try to timestamp the frame on egress (and crash)
                            mii_packet_set_timestamp_id(buf, 0);

#if ETHERNET_FILTER_ENABLE_USER_DATA
                            mii_packet_set_user_data(buf, user_data);
#endif

                            mii_packet_set_filter_result(buf, filter_result);
                            mii_packet_set_stage(buf, 1);
                        }


                    }
                    break;
                } // end if (buf)
            } // end case()
        } // end select
    } // end while (1)


#if ETHERNET_FILTER_ENABLE_USER_DATA
int mac_custom_filter_coerce1(unsigned int buf[], unsigned int mac[2], int &user_data)
#else
int mac_custom_filter_coerce1(unsigned int buf[], unsigned int mac[2])
#endif
{
#if ETHERNET_FILTER_ENABLE_USER_DATA
  return mac_custom_filter(buf, mac, user_data);
#else
//  return 0xffffffff;//
  return mac_custom_filter(buf, mac);
#endif
}
