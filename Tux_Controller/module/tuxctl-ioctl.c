/* tuxctl-ioctl.c
 *
 * Driver (skeleton) for the mp2 tuxcontrollers for ECE391 at UIUC.
 *
 * Mark Murphy 2006
 * Andrew Ofisher 2007
 * Steve Lumetta 12-13 Sep 2009
 * Puskar Naha 2013
 */

#include <asm/current.h>
#include <asm/uaccess.h>

#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/sched.h>
#include <linux/file.h>
#include <linux/miscdevice.h>
#include <linux/kdev_t.h>
#include <linux/tty.h>
#include <linux/spinlock.h>

#include "tuxctl-ld.h"
#include "tuxctl-ioctl.h"
#include "mtcp.h"

#define debug(str, ...) \
	printk(KERN_DEBUG "%s: " str, __FUNCTION__, ## __VA_ARGS__)

/************************ Protocol Implementation *************************/
//
#define CLEAR_LED 	0x00000000		// is this valid?
#define BUSY		1
#define FREE		0
// 
unsigned char button_state;	// initialize it ? 
unsigned int  ack_state;
unsigned char led_state[6];
unsigned int led_buf_size;

unsigned char charArray[16] = {0xE7, 0x06, 0xCB, 0x8F, 0x2E, 0xAD, 0xED, 0x86,
								0xEF, 0xAE, 0xEE, 0x6D, 0xE1, 0x4F, 0xE9, 0xE8};

// helper functions for ioctl
int tuxctl_init(struct tty_struct* tty);
int tuxctl_set_led(struct tty_struct* tty, unsigned long arg);
int tuxctl_buttons(struct tty_struct* tty, unsigned long arg);
int reset(struct tty_struct* tty);

// receiving data from the tux controller

/* tuxctl_handle_packet()
 * IMPORTANT : Read the header for tuxctl_ldisc_data_callback() in 
 * tuxctl-ld.c. It calls this function, so all warnings there apply 
 * here as well.
 */
void tuxctl_handle_packet (struct tty_struct* tty, unsigned char* packet)
{
    unsigned a, b, c;
	unsigned char left;
	unsigned char down;

	if (packet == NULL) {
		return;
	}

    a = packet[0]; /* Avoid printk() sign extending the 8-bit */ // what the packet is
    b = packet[1]; /* values when printing them. */
    c = packet[2];

    /*printk("packet : %x %x %x\n", a, b, c); */

	switch (a) {
	
	case MTCP_BIOC_EVENT:	// button

			button_state = 0x00;
			button_state = button_state | (b & 0x0F);	// four low bits
			button_state = button_state | ((c << 4) & 0xF0);	// four high bits
			button_state = button_state & 0x9F;	// set left and down bits to 0
			
			// switching left and down
			left = (c & 0x02) << 5;
			down = (c & 0x04) << 3;
			button_state = button_state | left;
			button_state = button_state | down;

			break;

	case MTCP_ACK:

			ack_state = FREE;
			break;

	case MTCP_RESET:
			
			reset(tty);
			break;

	default:
	    return;
    }

	return;
}
// interrupt descriptor table

/******** IMPORTANT NOTE: READ THIS BEFORE IMPLEMENTING THE IOCTLS ************
 *                                                                            *
 * The ioctls should not spend any time waiting for responses to the commands *
 * they send to the controller. The data is sent over the serial line at      *
 * 9600 BAUD. At this rate, a byte takes approximately 1 millisecond to       *
 * transmit; this means that there will be about 9 milliseconds between       *
 * the time you request that the low-level serial driver send the             *
 * 6-byte SET_LEDS packet and the time the 3-byte ACK packet finishes         *
 * arriving. This is far too long a time for a system call to take. The       *
 * ioctls should return immediately with success if their parameters are      *
 * valid.                                                                     *
 *                                                                            *
 ******************************************************************************/


/* tuxctl_ioctl()
 * 
 * 	Desription: Do a corresponding task (call a function) basead on cmd
 * 	Input:	cmd -- command that wants to perform
 * 			arg -- arguments needed for each cmd
 * 	Output: none
 * 	Side effect: none
 */
// any requests sent from the user program
int 
tuxctl_ioctl (struct tty_struct* tty, struct file* file, 
	      unsigned cmd, unsigned long arg)
{
    switch (cmd) {
	case TUX_INIT:
			// initialize tux controller
			return tuxctl_init(tty);
			
	case TUX_BUTTONS:
			// see what buttons are pressed
			return tuxctl_buttons(tty, arg);

	case TUX_SET_LED:
			// set the LED to whatever user wants
			return tuxctl_set_led(tty, arg);

	default:
	    return -EINVAL;
    }
}



/* reset()
 * 
 * 	Desription: Reset the buttons, restore the leds, turn on interrupt
 * 	Input:
 * 	Output: none
 * 	Side effect: none
 */
int reset(struct tty_struct* tty) {

	unsigned char buf [8];
	int i = 0;

	if (ack_state == BUSY) {
		return 0;		// do I return 0
	}

	buf[0] = MTCP_LED_USR;	// initialize LED	(to be used by user)
	buf[1] = MTCP_BIOC_ON;	// turn on interrupt

	// restore the previous led state 
	for (i = 0; i < led_buf_size; i++) {
		buf[i+2] = led_state[i];
	}

	// clear buttons (set all to 1) no buttons are pressed during the reset
	button_state = 0xFF;

	tuxctl_ldisc_put(tty, buf, 2+led_buf_size);

	ack_state = BUSY;

	return 0;
}


/* tuxctl_init()
 * 
 * 	Desription: Reset the buttons, initilziae the leds (to 0000), turn on interrupt
 * 	Input:
 * 	Output: none
 * 	Side effect: none
 */
int tuxctl_init(struct tty_struct* tty) {

	unsigned char buf [8];

	// CHECK IF CONTROLLER IS BUSY
	if (ack_state == BUSY) {
		return 0;		
	}

	buf[0] = MTCP_BIOC_ON;	// initialize LED	(to be used by user)
	buf[1] = MTCP_LED_USR;	// turn on interrupt
	// initialize LEDs to 0000
	buf[2] = MTCP_LED_SET;
	buf[3] = 0x0F;
	buf[4] = charArray[0];
	buf[5] = charArray[0];
	buf[6] = charArray[0];
	buf[7] = charArray[0];

	
	tuxctl_ldisc_put(tty, buf, 8);	// whenever you call put, you wanna call it once 

	ack_state = BUSY;

	return 0;
}


/* tuxctl_buttons()
 * 
 * 	Desription: read buttons (which buttons are pressed)
 * 	Input:	arg - which buttons are pressed
 * 	Output: none
 * 	Side effect: none
 */
int tuxctl_buttons(struct tty_struct* tty, unsigned long arg) {

	unsigned long check;
	
	// check arg validity
	if ((int*)arg == NULL) {
		return -EINVAL;
	}

	check = copy_to_user((int*)arg, &button_state, 1);

	if (check != 0) {
		return -EINVAL;
	}

	return 0;
}


/* tuxctl_set_led()
 * 
 * 	Desription: set leds to user defined value
 * 	Input:	arg - information about leds
 * 	Output: none
 * 	Side effect: none
 */
int tuxctl_set_led(struct tty_struct* tty, unsigned long arg) {

	unsigned char dp, ledOn;
	unsigned int ledValue;

	unsigned char tempLedOn;
	unsigned int tempLedVal;
	unsigned char tempDp;

	int i = 0;

	// check if controller is busy
	if (ack_state == BUSY) {
		return 0;		
	}
	
	dp = (arg & (0xF000 << 12)) >> 24;			// decimal point
	ledOn = (arg & (0xF000 << 4)) >> 16;		// which leds are on
	ledValue = arg & 0xFFFF;					// num to show on leds

	led_state[0] = MTCP_LED_SET;
	led_state[1] = 0x0F;	
	led_buf_size = 2;

	tempLedOn = ledOn;
	tempLedVal= ledValue;
	tempDp = dp;
		
	for (i = 0; i < 4; i++) {
		if((tempLedOn & 0x01) == 1) {
			led_state[i+2] = charArray[tempLedVal & 0x000F];
			
		} else {
			led_state[i+2] = 0x00;
		}
		
		if ((tempDp & 0x01) == 1) {
			led_state[i+2] = led_state[i+2] | 0x10;
		}
		
		led_buf_size++;

		tempDp = tempDp >> 1;
		tempLedOn = tempLedOn >> 1;
		tempLedVal = tempLedVal >> 4;
	}

	tuxctl_ldisc_put(tty, led_state, 6);


	ack_state = BUSY;

	return 0;
}


