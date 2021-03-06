;***********************************************************
;*
;* 	ECE 375 Lab 6 - Fall 2012
;*	Robot.asm
;*
;*	This is the robot for Lab 6 of ECE 375. The robot waits
;* 	until it receives a signal, then checks to see if it is 
;*	be the Freezing command from another robot. If it is the 
;*	Freezing command, the Robot will halt for five seconds 
;*	then resume forward motion. After being frozen three times, 
;*	the Robot will be permanently frozen until the Reset
;*	Button is pressed. If it is not the freezing command, the 
;*	robot checks to see if it is a corresponding BotID. If it 
;*	is, it waits for the next command it receives and performs 
;*	the corresponding action. 
;*
;*	The robot also has bumpbot capabilities.
;*
;***********************************************************
;*
;*	 Author: Devlin Junker
;*	   Date: November 11th, 2012
;*
;***********************************************************

.include "m128def.inc"			; Include definition file

;***********************************************************
;*	Internal Register Definitions and Constants
;***********************************************************
.def	mpr = r16				; Multi-Purpose Register
.def	sigr = r17				; Signal Register
.def	waitcnt = r18			; Wait Loop Counter
.def 	ilcnt = r19 			; Inner Loop Counter
.def	olcnt = r20				; Outer Loop Counter
.def	frzcnt = r21			; Number of Freezes Counter
.def 	loopcnt = r22

; Wait Time Constant
.equ	WTime = 100

; Constants for interactions
.equ	WskrR = 0				; Right Whisker Input Bit
.equ	WskrL = 1				; Left Whisker Input Bit

.equ 	ResetBtn = 7			; Reset Button Input Bit

.equ	EngEnR = 4				; Right Engine Enable Bit
.equ	EngEnL = 7				; Left Engine Enable Bit
.equ	EngDirR = 5				; Right Engine Direction Bit
.equ	EngDirL = 6				; Left Engine Direction Bit

.equ	BotID = 0b00110011		; Unique XD ID (MSB = 0)

;/////////////////////////////////////////////////////////////
;These macros are the values to make the TekBot Move.
;/////////////////////////////////////////////////////////////

.equ	MovFwd =  (1<<EngDirR|1<<EngDirL)	;0b01100000 Move Forwards Command
.equ	MovBck =  $00						;0b00000000 Move Backwards Command
.equ	TurnR =   (1<<EngDirL)				;0b01000000 Turn Right Command
.equ	TurnL =   (1<<EngDirR)				;0b00100000 Turn Left Command
.equ	Halt =    (1<<EngEnR|1<<EngEnL)		;0b10010000 Halt Command
.equ	Freez =   $F0						;0b11110000 Send Freeze Command
.equ	Freezing =   $D5					;0b11010101 Freeze Command

;***********************************************************
;*	Start of Code Segment
;***********************************************************
.cseg							; Beginning of code segment

;-----------------------------------------------------------
; Interrupt Vectors
;-----------------------------------------------------------
.org	$0000					; Beginning of IVs
		rjmp 	INIT			; Reset interrupt

.org	$0002					; INT0 Interrupt Vector
		rcall	HitRight		; Function to handle Hit Right
		reti					; Return from interrupt

.org 	$0004					; INT1 Interrupt Vector
		rcall 	HitLeft			; Function to handle Hit Lef
		reti					; Return from interrupt

;.org 	$0006					; INT2 Interrupt Vector
		;call Freeze			; FOR TESTING FREEZE

.org 	$003C					; USART1 Receiver Interrupt
		rcall 	ReceiveID
		reti

.org	$0046					; End of Interrupt Vectors

;-----------------------------------------------------------
; Program Initialization
;-----------------------------------------------------------
INIT:
	;Stack Pointer 
	ldi mpr, HIGH(RAMEND)
	out SPH, mpr
	ldi mpr, LOW(RAMEND)
	out SPL, mpr

	; Initialize Port B for output
	ldi mpr, $FF
	out DDRB, mpr			; Set Port B as Output
	ldi mpr, $00
	out PORTB, mpr			; Default Output set 0

	; Initialize Port D for input
	ldi mpr, $00
	out DDRD, mpr			; Set Port D as Input
	ldi mpr, (1<<WskrL)|(1<<WskrR)|(1<<ResetBtn)
	;ldi mpr, (1<<WskrL)|(1<<WskrR)|(1<<ResetBtn)|(1<<2) ; FOR TESTING FREEZE
	out PORTD, mpr			; Set Input to Hi-Z
	
	
	;USART1
	;Enable receiver and Enable receive interrupts
	ldi mpr, (1<<RXEN1)|(1<<RXCIE1)
	sts UCSR1B, mpr
	
	;Set frame format: 8data, 2 stop bit
	ldi mpr, (1<<USBS1)|(3<<UCSZ10)
	sts UCSR1C,mpr
	
	;Set baudrate at 2400bps
	ldi mpr, $01
	sts UBRR1H, mpr
	ldi mpr, $A0
	sts UBRR1L, mpr


	; Initialize external interrupts
	; Set the Interrupt Sense Control to Falling Edge detection
	ldi mpr, (1<<ISC01)|(0<<ISC00)|(1<<ISC11)|(0<<ISC10)
	;ldi mpr, (1<<ISC01)|(0<<ISC00)|(1<<ISC11)|(0<<ISC10)|(1<<ISC21)|(0<<ISC20) ; FOR TESTING FREEZE
	sts EICRA, mpr
	ldi mpr, $00	
	out EICRB, mpr

	; Set the External Interrupt Mask
	ldi mpr, (1<<INT0)|(1<<INT1)
	;ldi mpr, (1<<INT0)|(1<<INT1)|(1<<INT2) ; FOR TESTING FREEZE
	out EIMSK, mpr

	; Enable Interrupts
	sei	

	; Set Freeze Counter
	ldi frzcnt, 3		
	
	; Send command to Move Robot Forward 
	ldi mpr, MovFwd
	out PORTB, mpr

;-----------------------------------------------------------
; Main Program
;-----------------------------------------------------------
MAIN:

	rjmp	MAIN	

;***********************************************************
;*	Functions and Subroutines
;***********************************************************
;-----------------------------------------------------------
; Func: ReceiveID
; Desc: Obtains first signal from receiver buffer and checks
; 		if it is the freeze code from another robot. If it is,
; 		calls the freeze routine. If not, it compares against
; 		the designated BotID. If our ID, it polls the receiver
; 		complete flag until command received then call ReceiveCmd
;-----------------------------------------------------------
ReceiveID:	
		; Save variable by pushing them to the stack
		push sigr
		push mpr
		in mpr, SREG
		push mpr
		
		lds sigr, UDR1 	; Get signal from buffer
		
		; Check if is a BotId
		sbrs sigr, 7		;(If 7th bit is not set, it is a BotID)
		rjmp CheckID	;If it is, jump to checkID	
						
						;if it's not, check if Robot should freeze
		cpi sigr, Freezing
		brne End		; if not, return to main
		
		call Freeze		; else call Freeze Routine
		rjmp End		; then return to main

CheckID:	; Check if our BotID
		cpi sigr, BotID	
		brne End		; If not, return to main

CmdLoop:	; Wait to recieve Command
		lds mpr, UCSR1A
		sbrs mpr, RXC1		; Check if Recieve Complete
		rjmp CmdLoop		; If not, wait for Recieve Complete

		; If Complete: Jump to RecieveCmd
		rcall ReceiveCmd	

End: 
		; Restore variable by popping them from the stack in reverse order
		pop mpr
		out SREG, mpr
		pop mpr
		pop sigr
		ret		; End a function with RET

;-----------------------------------------------------------
; Func: Hit_Right
; Desc: Handles when Right Whisker is triggered
;		Moves TekBot backwards for 1 second, then 
;		turns left for 1 second, then continues forward
;-----------------------------------------------------------
HitRight:
		; Save variable by pushing them to the stack
		push mpr
		push waitcnt
		in mpr, SREG
		push mpr		

		; Move Backwards for 1 Second
		ldi mpr, MovBck
		out PORTB, mpr
		rcall Wait
		
		; Turn Left for 1 Second
		ldi mpr, TurnL
		out PORTB, mpr
		rcall Wait
		
		; Begin Moving Forward
		ldi mpr, MovFwd
		out PORTB, mpr

		; Restore variable by popping them from the stack in reverse order
		pop mpr
		out SREG, mpr
		pop waitcnt
		pop mpr
		ret		; End a function with RET


;-----------------------------------------------------------
; Func: Hit_Left
; Desc: Handles when Left Whisker is triggered
;		Moves TekBot backwards for 1 second, then 
;		turns right for 1 second, then continues forward
;-----------------------------------------------------------
HitLeft:
		; Save variable by pushing them to the stack
		push mpr
		push waitcnt
		in mpr, SREG
		push mpr		

		; Move Backwards for 1 Second
		ldi mpr, MovBck
		out PORTB, mpr
		rcall Wait
		
		; Turn Right for 1 Second
		ldi mpr, TurnR
		out PORTB, mpr
		rcall Wait

		; Begin Moving Forward
		ldi mpr, MovFwd
		out PORTB, mpr		

		; Restore variable by popping them from the stack in reverse order
		pop mpr
		out SREG, mpr
		pop waitcnt
		pop mpr
		ret		; End a function with RET

;-----------------------------------------------------------
; Func: Wait
; Desc: Wait loop that will wait for WTime*(~10ms)
;		beginning of your functions
;-----------------------------------------------------------
Wait:	
		; Save variable by pushing them to the stack
		push waitcnt
		push ilcnt
		push olcnt

		ldi waitcnt, WTime

Loop:	ldi olcnt, 224
OLoop:	ldi ilcnt, 237
ILoop:	dec ilcnt
		brne ILoop
		dec olcnt
		brne OLoop
		dec waitcnt
		brne Loop
		
		; Restore variable by popping them from the stack in reverse order
		pop olcnt
		pop ilcnt
		pop waitcnt
		ret		; End a function with RET

;-----------------------------------------------------------
; Func: ReceiveCmd
; Desc: Obtains second signal from receiver buffer once BotID matches
; 		and checks if it is the Send Freeze Command. If it is, it calls
;		the SendFreeze routine. Otherwise, it outputs the command to
; 		the motors.
;-----------------------------------------------------------
ReceiveCmd:	
		; Save variable by pushing them to the stack
		push mpr
		in mpr, SREG
		push mpr
		
		lds mpr, UDR1 	; Get command from buffer
		lsl mpr			; Left Shift out MSB (1 to represent signal)

		; Check if Freeze Command
		cpi mpr, Freez	; Compare against Freeze Command 
		brne motorCmd	; If not Freeze jump to MotorCmd

		rcall SendFreeze; If equal, call Send Freeze Routine
		rjmp exit

motorCmd:; If Motor Command, send to Motors
		out PORTB, mpr			

exit: 
		; Restore variable by popping them from the stack in reverse order
		pop mpr
		out SREG, mpr
		pop mpr
		ret		; End a function with RET

;-----------------------------------------------------------
; Func: sendFreeze
; Desc: Sends the freeze command to any other robots it's IR signal
; 		reaches.
;-----------------------------------------------------------
SendFreeze:	
		; Save variable by pushing them to the stack
		push mpr
		in mpr, SREG
		push mpr
		

		;Enable transmitter and disable reciever
		ldi mpr, (1<<TXEN1)|(1<<RXCIE1)
		sts UCSR1B, mpr	

		; Load in Freezing Command
		ldi mpr, Freezing
		sts UDR1, mpr		; Transmit Command

transmitLoop:	; Wait for any transmissions to finish
		lds mpr, UCSR1A	
		sbrs mpr, UDRE1	
		rjmp transmitLoop	; Loop if transmission not finished

		;Enable reciever and disable transmitter
		ldi mpr, (1<<RXEN1)|(1<<RXCIE1)
		sts UCSR1B, mpr	
	
		; Restore variable by popping them from the stack in reverse order
		pop mpr
		out SREG, mpr
		pop mpr
		ret		; End a function with RET


;-----------------------------------------------------------
; Func: Freeze
; Desc: Freezes the robot for 5 seconds, then restarts it moving
; 		forward. If it has been frozen 3 times, it calls the Frozen 
;		routine that freezes the robot until it is reset.
;-----------------------------------------------------------
Freeze:	
		; Save variable by pushing them to the stack
		push mpr
		in mpr, SREG
		push mpr
		
		; Freeze Robot
		ldi mpr, Halt	
		out PORTB, mpr		
		
		; Wait 5 Seconds
		ldi loopcnt, 5
FreezeLoop: ; Loop Wait 1 Second 5 times
		rcall Wait
		dec loopcnt
		brne FreezeLoop

		; Decrement Freeze Counter
		dec frzcnt
		brne Return	; If Freeze Counter is Not Zero, return 
		rcall Frozen	; Else, Freeze until reset
		
Return:	; Begin Moving Forward again
		ldi mpr, MovFwd
		out PORTB, mpr

		; Restore variable by popping them from the stack in reverse order
		pop mpr
		out SREG, mpr
		pop mpr
		ret		; End a function with RET
		;reti	; FOR TESTING FREEZE

;-----------------------------------------------------------
; Func: Frozen
; Desc: Freezes the robot indefinitely by polling the buttons until
; 		the 7th button has been pressed to reset the robot.
;-----------------------------------------------------------
Frozen:	
		; Save variable by pushing them to the stack
		push mpr
		in mpr, SREG
		push mpr
		
FrozenLoop:	; Loop until Reset Button Pressed
		in mpr, PIND		; Get Button Input
		sbrc mpr, ResetBtn	; If Reset Button is Pressed (Active Low) escape loop
		rjmp FrozenLoop		; Else, continue looping

		ldi frzcnt, 3		; Reset Freeze Counter

		; Restore variable by popping them from the stack in reverse order
		pop mpr
		out SREG, mpr
		pop mpr
		ret		; End a function with RET


;***********************************************************
;*	Stored Program Data
;***********************************************************



;***********************************************************
;*	Additional Program Includes
;***********************************************************

