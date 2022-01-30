
.data                                   # section declaration

        # Useful offset constants for accessing members of a 
        # struct mp1_blink_struct structure
        LOCATION   = 0    
        ON_CHAR    = 2
        OFF_CHAR   = 3 
        ON_LENGTH  = 4
        OFF_LENGTH = 6
        COUNTDOWN  = 8
        STATUS     = 10
        NEXT       = 12

        STRUCT_SIZE = 16

# Pointer to head of list (initialized to NULL)
mp1_list_head:
        .long   0

.text                                   # section declaration

# Export the function symbol names

.global mp1_rtc_tasklet
.global mp1_ioctl

# void mp1_poke(void);
#
# Interface: Register-based arguments (not C-style)
#    Inputs: %cl  - The byte you wish to write
#            %eax - Offset from the start of video memory that you wish
#                   to write to
#   Outputs: Text-mode video screen is written to at location %eax with
#            the byte in %cl
# Registers: Clobbers EDX
mp1_poke:
        
        movl    vmem_base_addr(,1),%edx
        movb    %cl,(%edx,%eax,1)
        ret

# void mp1_rtc_tasklet(unsigned long)
#
#  Inputs: none
#  Outputs: video screen is written
#
mp1_rtc_tasklet:
        pushl %ebp
        movl %esp, %ebp

        pushl %ebx      /* Callee-save Registers */
        pushl %esi
        pushl %edi

       
        movl mp1_list_head, %ebx      /* store mp1_list_head to ebx */

        cmpl $0, %ebx         # check if ebx is 0 (if mp_list_head is null)
        je DONE_TASKLET       # if mp_list_head is null, jump to DONE_TASKLET

        xorl %ecx, %ecx
        
     LOOP_DECREMENT:
        # decrement countdown
        movw COUNTDOWN(%ebx), %cx
        subw $1, %cx
        movw %cx, COUNTDOWN(%ebx)

        # Is countdown == 0 ?
        cmpw $0, COUNTDOWN(%ebx)
        
        # YES ==> check status
        # NO ==> jump to NEXT_ELEM
        je CHECK_STATUS
        jmp NEXT_ELEM

     CHECK_STATUS:
        cmpw $1, STATUS(%ebx)
        je CURR_ON

        cmpw $0, STATUS(%ebx)
        je CURR_OFF

     CURR_ON:  # the current status is ON (1)
        # put off_char and update countdown with off_length
        xorl %eax, %eax
        movw LOCATION(%ebx), %ax

        shll $1, %eax                   /* multiply it by 2 */
        movb OFF_CHAR(%ebx), %cl       /* char 1 byte */
        call mp1_poke
        movw $0, STATUS(%ebx)       # set STATUS to 0
        xorl %eax, %eax
        movw OFF_LENGTH(%ebx), %ax     # set COUNTDOWN to OFF_LENGTH
        
        movw %ax, COUNTDOWN(%ebx)
        jmp NEXT_ELEM

     CURR_OFF:
        # put on_char and update COUNTDOWN with ON_LENGTH
        xorl %eax, %eax
        movw LOCATION(%ebx), %ax

        shll $1, %eax                   /* multiply it by 2 */
        movb ON_CHAR(%ebx), %cl       
        call mp1_poke
        movw $1, STATUS(%ebx)          # set STATUS to 1

        xorl %eax, %eax
        movw ON_LENGTH(%ebx), %ax      # set COUNTDOWN to ON_LENGTH
        movw %ax, COUNTDOWN(%ebx)

     NEXT_ELEM:
        # tasklet moves on to the next list element
        movl NEXT(%ebx), %ebx

        # is it End of List ?
        cmpl $0, %ebx

        # YES ==> DONE
        # NO ==> LOOP_DECREMENT
        je DONE_TASKLET
        jmp LOOP_DECREMENT

     DONE_TASKLET:
        popl %edi       /* Restore callee-saved registers */
        popl %esi
        popl %ebx 

        movl $0, %eax 
        leave

      
        ret

# int mp1_ioctl (unsigned long arg, unsigned long cmd)
#
#     Input: arg - will be passed to core functions
#            cmd - the corresponding core function
#     Output: jump to the corresponding core function
#              returns -1 if no corresponding core function exists
#
mp1_ioctl:
      
        movl 8(%esp), %ecx    /* store cmp to ecx */
 
         # check if cmp is within the bound (0-3). If not, jump to RETURN_ERROR
        cmpl $3, %ecx        
        ja RETURN_ERROR
        cmpl $0, %ecx
        jb RETURN_ERROR
       
        jmp *jump_table(, %ecx, 4)
        /* Jump Table */
        jump_table:
        .long mp1_ioctl_add, mp1_ioctl_remove, mp1_ioctl_find, mp1_ioctl_sync

   RETURN_ERROR:
        movl $-1, %eax

        ret

# int mp1_ioctl_add (unsigned long arg)
#     Input: arg - a user-level pointer to a mp1_blink_struct structure
#
#     Output: store a copy the structure
#              returns -1 if an error occurs
#
mp1_ioctl_add:
        pushl %ebp
        movl %esp, %ebp

        pushl %ebx      /* Store Callee-save Registers */
        pushl %esi
        pushl %edi

        /* allocate memory */
        pushl $STRUCT_SIZE
        call mp1_malloc
        addl $4, %esp   /* pop STRUCT_SIZE */
        movl %eax, %ebx         /* store the return value of mp1_malloc (void*) to ebx */

        cmpl $0, %ebx    /* return -1 if the return value is not valid (if it is null) */
        je ERROR_RETURN1         

        /* copy the struct */
        movl 8(%ebp), %ecx       # move arg to ecx
        cmpl $0, %ecx
        je ERROR_RETURN2

        pushl $STRUCT_SIZE
        pushl %ecx           /* represents '*from' (arg) */
        pushl %ebx              /* represents '*to' */
        
        call mp1_copy_from_user
        addl $12, %esp          

        # check if copied properly by checking the return value of copy_from_user (stored in eax)
        # If eax is not 0, jump to ERROR_RETURN2
        cmpl $0, %eax      
        jne ERROR_RETURN2
    
        /* check if location is within the range 0-1999 */
        cmpw $1999, LOCATION(%ebx)     # 1999 = 80*25-1 => boundary of LOCATION
        ja ERROR_RETURN2

        cmpw $0, LOCATION(%ebx)        # 0 => boundary of LOCATION
        jb ERROR_RETURN2

        /* set the countdown field to be equal to the on length field, and set the status field to 1.*/
        xorl %ecx, %ecx
        movw ON_LENGTH(%ebx), %cx      # set COUNTDOWN to ON_LENGTH
        movw %cx, COUNTDOWN(%ebx)
        movw $1, STATUS(%ebx)          # set STATUS to 1


        /* Insert the structure at the head of the linked list */
        movl mp1_list_head, %ecx
        movl %ecx, NEXT(%ebx)
        movl %ebx, mp1_list_head
        
        # display        
        xorl %eax, %eax
        movw LOCATION(%ebx), %ax       # eax: offset from the start of video memory
        shll $1, %eax               /* multiply it by 2 */
        movb ON_CHAR(%ebx), %cl        # cl: ASCII code of character to write
        
        call mp1_poke
        jmp DONE
        
      # free the newly allocated memory
      ERROR_RETURN2:
        pushl %ebx    
        call mp1_free
        addl $4, %esp

      # return -1 (error occured)
      ERROR_RETURN1:     
      
        movl $-1, %eax
        jmp DONE2

      # return 0
      DONE:
        movl $0, %eax 
      DONE2:

        popl %edi       /* Restore callee-saved registers */
        popl %esi
        popl %ebx 

        
        leave
        ret

# int mp1_ioctl_remove (unsigned long arg)
#
#     Input: arg - an integer location
#
#     Output: Remove an element whose location field matches the argument from the list
#              returns -1 if no matching element found
#              returns 0 otherwise
#        
mp1_ioctl_remove:
        pushl %ebp
        movl %esp, %ebp

        pushl %ebx      /* Callee-save Registers */
        pushl %esi
        pushl %edi

        movl 8(%ebp), %ebx      # ebx: holds arg passed to the func
        movl mp1_list_head, %ecx        # ecx: curr elem in list. Initialize it to mp1_list_head

        # check if the head is null. If it is null, jump to NOT_FOUND_REMOVE
        cmpl $0, %ecx
        je NOT_FOUND_REMOVE

        # check if the head element has the same LOCATION
        cmpw LOCATION(%ecx), %bx
        je HEAD_REMOVE           # YES => jump to HEAD_REMOVE
        jmp LOOP_SEARCH_REMOVE  # NO => jump to LOOP_SEARCH_REMOVE

      # remove head (the first elem of the list)
      HEAD_REMOVE:
        # mp1_list_head points to head's next
        movl NEXT(%ecx), %edx       
        movl %edx, mp1_list_head          
        
        # free head of the list
        pushl %ecx
        call mp1_free
        addl $4, %esp
        
        # set the return value to 0 and jump to DONE_REMOVE to return
        movl $0, %eax      
        jmp DONE_REMOVE   

      # removing an element that is not the head of the list
      LOOP_SEARCH_REMOVE:
        # ecx : current elem, eax: next elem (current's next)
        movl NEXT(%ecx), %eax       # store the next elem to eax (update the next element)
        cmpl $0, %eax               # if the next elem is null, which means no matching elem exists,
        je NOT_FOUND_REMOVE         # jump to NOT_FOUND_REMOVE

        cmpw LOCATION(%eax), %bx    # check if next's LOCATION matches ebx (ebx: holds arg passed to the func)
        je FOUND_REMOVE             # yes => jump to FOUND_REMOVE

        # update the current element
        movl NEXT(%ecx), %ecx
        jmp LOOP_SEARCH_REMOVE

      # free the matching elem (stored in eax, which is the next element holder)
      FOUND_REMOVE:
         # set the current's next to next elem's next (since it is freeing next elem)
        movl NEXT(%eax), %edx
        movl %edx, NEXT(%ecx)
        movl $0, NEXT(%eax)

        # free eax
        pushl %eax
        call mp1_free
        addl $4, %esp

        # set the return value to 0 and jump to DONE_REMOVE to return
        movl $0, %eax
        jmp DONE_REMOVE

      # set the return value to -1 (error occurred)
      NOT_FOUND_REMOVE:
        movl $-1, %eax

      DONE_REMOVE:

        popl %edi       /* Restore callee-saved registers */
        popl %esi
        popl %ebx 

        leave
        ret

# int mp1_ioctl_find (unsigned long arg)
#
#        Input: arg - a user-level pointer to a mp1_blink_struct structure
#
#        Output: store a copy of the structure that matches location field
#                 return -1 if error occurs or no matching element found
#                 return 0 otherwise
#      
mp1_ioctl_find:
        pushl %ebp
        movl %esp, %ebp

        pushl %ebx      /* Callee-save Registers */
        pushl %esi
        pushl %edi

        movl 8(%ebp), %ecx      # ecx: holds arg passed to the func (pointer to struct in user-level)

        # check if the pointer refers to a valid structure
        cmpl $0, %ecx      # if the pointer is null, jump to NOT_FOUND
        je NOT_FOUND

        /* allocate memory */
        pushl $STRUCT_SIZE        
        call mp1_malloc
        addl $4, %esp   
        xorl %ebx, %ebx
        movl %eax, %esi         /* store the return value (void*) to esi */

        cmpl $0, %esi    /* check if the ptr is valid. If not, return -1 (jump to NOT_FOUND) */
        je NOT_FOUND         

      /* copy the struct */
        pushl $STRUCT_SIZE
         movl 8(%ebp), %ecx
        pushl %ecx           /* represents '*from' (arg) */
        pushl %esi              /* represents '*to' */

        call mp1_copy_from_user
        addl $12, %esp          

        cmpl $0, %eax         # check if copied properly
        jne NOT_FOUND2
    

        # esi : ptr to the newly allocated memory address for the extracted LOCATION
        movl 8(%ebp), %ecx      # ecx: pointer to struct in user-level structure (arg)

        # check if the pointer refers to a valid structure
        cmpl $0, %ecx
        je NOT_FOUND

        xorl %ebx, %ebx
        movw LOCATION(%ecx), %bx        # store LOCATION of arg to bx
        movl mp1_list_head, %ecx        # store head of the list to ecx (ecx: curr elem in the list)

      LOOP_SEARCH:
        cmpl $0, %ecx   # check if the curr elem is null
        je NOT_FOUND

        cmpw LOCATION(%ecx), %bx    # check if LOCATION of curr elem matches LOCATION of arg (passed to func)
        je FOUND
        
        movl NEXT(%ecx), %ecx       # update curr elem to next elem
        jmp LOOP_SEARCH

     # matching elem found => copy the struct to user-level (arg passed to func)
     FOUND:
        # copy to user-level 
        pushl $STRUCT_SIZE
        pushl %ecx               # from   ecx: curr elem
        movl 8(%ebp), %ebx       # to     ebx: arg
        pushl %ebx

        call mp1_copy_to_user
        addl $12, %esp

        cmpl $0, %eax            # check if copied properly
        jne NOT_FOUND2           # if not, jump to NOT_FOUND2

        movl $0, %eax           # set return value to 0

        pushl %esi               # free the newly allocated memory
        call mp1_free
        addl $4, %esp
        jmp RETURN               # jump to RETURN to return 0
         
     # free the newly allocated memory
     NOT_FOUND2:
         pushl %esi    
        call mp1_free
        addl $4, %esp
        
     NOT_FOUND:
        movl $-1, %eax          # error => return -1

     RETURN:
        popl %edi       /* Restore callee-saved registers */
        popl %esi
        popl %ebx 
   
        leave
        ret

# int mp1_ioctl_sync (unsigned long arg)
#
#        Input: two two-byte unsigned short integers
#               first int – the upper 16 bits in arg
#               second int – the lower 16 bits in arg
#
#        Output: synchronizes two existing locations on the screen
#                 return -1 if an error occurs
#                 return 0 on success
#
mp1_ioctl_sync:
        pushl %ebp
        movl %esp, %ebp
        
        pushl %ebx      /* Callee-save Registers */
        pushl %esi
        pushl %edi

        xorl %eax, %eax
        xorl %ebx, %ebx
        xorl %ecx, %ecx
 
        # first int in cx, second int in dx
        movl 8(%ebp), %eax      # store argument to eax
        movw %ax, %dx           # second int (the lower 16 bits) in dx
        shrl $16, %eax
        movw %ax, %cx           # first int (the upper 16 bits) in cx
       
        movl mp1_list_head, %ebx   # mp1_list_head in ebx   (ebx holds the curr elem)

      # find matching elem of the first int
      # ebx: curr elem
      LOOP_FIRST:
        cmpl $0, %ebx               # check if curr is null
        je NOT_FOUND_SYNC

        cmpw LOCATION(%ebx), %cx    # check if LOCATION matches 
        je FOUND_FIRST

        movl NEXT(%ebx), %ebx       # update the curr elem
        jmp LOOP_FIRST
      
      FOUND_FIRST:
        movl %ebx, %ecx             # ecx holds the matching elem of the first int
        movl mp1_list_head, %ebx    # head in ebx

      # find matching elem of the second int
      # ebx: curr elem
      LOOP_SECOND:
        cmpl $0, %ebx               # check if curr is null
        je NOT_FOUND_SYNC

        cmpw LOCATION(%ebx), %dx    # check if LOCATION matches
        je FOUND_SECOND

        movl NEXT(%ebx), %ebx       # update the curr elem
        jmp LOOP_SECOND

      FOUND_SECOND:
        movl %ebx, %edx         # edx holds the matching elem of the second int

      # found matching elements
      # copy the timing information
      SEARCH_DONE:
        xorl %ebx, %ebx         # ebx: temp, copying ON_LENGTH
        movw ON_LENGTH(%ecx), %bx
        movw %bx, ON_LENGTH(%edx)

        xorl %ebx, %ebx         # ebx: temp, copying OFF_LENGTH
        movw OFF_LENGTH(%ecx), %bx
        movw %bx, OFF_LENGTH(%edx)

        xorl %ebx, %ebx         # ebx: temp, copying COUNTDOWN
        movw COUNTDOWN(%ecx), %bx
        movw %bx, COUNTDOWN(%edx)

        xorl %ebx, %ebx         # ebx: temp, copying STATUS
        movw STATUS(%ecx), %bx
        movw %bx, STATUS(%edx)

        # display
        xorl %eax, %eax
        movw LOCATION(%edx), %ax       # eax: offset 

        shll $1, %eax                   /* multiply it by 2 */

        cmpl $1, STATUS(%edx)          # current STATUS is 1 (ON)
        je ON_SYNC
        cmpl $0, STATUS(%edx)          # current STATUS is 0 (OFF)
        je OFF_SYNC

      ON_SYNC:     # current STATUS is ON
        movb ON_CHAR(%edx), %cl       
        jmp CALL_POKE
      OFF_SYNC:    # current STATUS is OFF
        movb OFF_CHAR(%edx), %cl

      CALL_POKE:
        call mp1_poke
        jmp DONE_SYNC
      
      # set return value to -1 (error)
      NOT_FOUND_SYNC:
        movl $-1, %eax
        jmp RETURN_SYNC          # jump to RETURN_SYNC to return
      
      # set return value to 0
      DONE_SYNC:
        movl $0, %eax

      RETURN_SYNC: 
        popl %edi       /* Restore callee-saved registers */
        popl %esi
        popl %ebx 

        leave
        ret

        
.end

